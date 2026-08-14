defmodule PerpWalk.Markets.Services.Trader do
  @moduledoc """
  Opens positions on `:active` markets.

  A trade quotes the AMM for a fixed contract count, applies the
  resulting pool, builds a new `Position`, and persists market and
  position together via `Store.put_trade/2` — a single atomic WAL
  write. Taking a position MUST atomically update the pool and the
  reservation, or fail entirely.

  Cost is computed in pool-reserve units (contracts) and converted
  to atomic monetary units via the market's `unit_size`. The
  resulting `amount_paid` is what gets recorded on the position; the
  actual XMR transfer happens in the Monero domain.
  """

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Guards
  alias PerpWalk.Markets.{AMM, Market, Position, Quote, Store}
  alias PerpWalk.Monero.Address, as: MoneroAddress
  alias PerpWalk.Monero.Facade, as: MoneroFacade

  @default_quote_window_seconds 1800

  @doc """
  Opens a position of `contracts` on `side` (`:yes` | `:no`) on the
  given `:active` market for `account_id`.

  Returns `{:ok, position}` with the newly created `Position.t()`.

  Errors:
  - `:market_not_found` — no such market id
  - `:market_not_active` — market is not in `:active` status
  - `:insufficient_liquidity` — trade would empty the source side
  """
  @spec place_position(binary(), binary(), AMM.side(), pos_integer()) ::
          {:ok, Position.t()}
          | {:error,
             :market_not_found
             | :market_not_active
             | :creator_cannot_trade_own_market
             | :insufficient_liquidity}
  def place_position(account_id, market_id, side, contracts)
      when is_binary(account_id) and is_binary(market_id) and side in [:yes, :no] and
             is_integer(contracts) and contracts > 0 do
    Guards.ensure_operational!()
    refuse_in_prod!()

    with {:ok, market} <- fetch_market(market_id),
         :ok <- ensure_active(market),
         :ok <- ensure_not_creator(market, account_id),
         contracts_subunits = AMM.to_subunits(contracts),
         {:ok, %{cost: cost_subunits, spread: spread_subunits, pool: new_pool}} <-
           AMM.quote_breakdown(market.pool, side, contracts_subunits),
         {:ok, updated_market} <- Market.update_pool(market, new_pool) do
      amount_paid = AMM.cost_to_piconeros(cost_subunits, market.unit_size)
      spread_piconeros = AMM.cost_to_piconeros(spread_subunits, market.unit_size)
      position = Position.new(market.id, account_id, side, contracts, amount_paid, spread_piconeros)

      # Propagate WAL back-pressure (`{:error, :wal_overloaded}`)
      # rather than crashing — callers retry on next tick.
      # `expected` is the pre-trade snapshot the AMM update was
      # computed against; the store CAS-checks the live market
      # against it and refuses on `:concurrent_modification` so a
      # racing trade can't clobber our pool update.
      expected = %{pool: market.pool, status: market.status}

      case Store.put_trade(updated_market, position, expected) do
        :ok ->
          EventBus.publish(%MarketsEvents.PositionOpened{
            position_id: position.id,
            market_id: market.id,
            account_id: account_id,
            side: side,
            contracts: contracts,
            amount_paid: amount_paid,
            timestamp: DateTime.utc_now()
          })

          {:ok, position}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Creates a pending Quote for a trade. Locks in the price at quote
  time and returns a fresh subaddress for the user to deposit into.

  Unlike `place_position/4`, the AMM does **not** move at quote time
  — it moves only when the deposit confirms via `fill_quote/2`.
  Two quotes against the same market may both reference the same
  starting pool state; whichever fills first gets the locked price,
  the other gets re-quoted at fill time.

  ## Options

  - `:subaddress_provider` (0-arity fun) — defaults to
    `PerpWalk.Monero.Facade.create_subaddress/0`. Injectable so a
    caller can supply a stubbed generator that avoids hitting the
    wallet RPC.
  - `:expires_in_seconds` — quote validity window. Defaults to
    1800 (30 minutes), enough for a Monero confirmation while still
    bounding how long the price stays locked.

  ## Errors

  - `:market_not_found`
  - `:market_not_active`
  - `:insufficient_liquidity`
  - `:wal_overloaded` — WAL back-pressure exhausted the Store's retry
    budget; the caller can retry.
  - `{:subaddress_provider_failed, term()}`

  Raises `PerpWalk.Guards.SystemHaltedError` if the system is halted.
  """
  @spec create_quote(binary(), binary(), AMM.side(), pos_integer(), keyword()) ::
          {:ok, Quote.t()}
          | {:error,
             :market_not_found
             | :market_not_active
             | :creator_cannot_trade_own_market
             | :insufficient_liquidity
             | :refund_address_required
             | :refund_address_invalid
             | :wal_overloaded
             | {:subaddress_provider_failed, term()}}
  def create_quote(account_id, market_id, side, contracts, opts \\ [])
      when is_binary(account_id) and is_binary(market_id) and side in [:yes, :no] and
             is_integer(contracts) and contracts > 0 do
    Guards.ensure_operational!()

    provider =
      opts
      |> Keyword.get(
        :subaddress_provider,
        Application.get_env(:perpwalk, :subaddress_provider, &MoneroFacade.create_subaddress/0)
      )
      |> normalize_provider()

    expires_in =
      Keyword.get(opts, :expires_in_seconds, @default_quote_window_seconds)

    with :ok <- ensure_refund_address(Keyword.get(opts, :refund_address)),
         refund_address = Keyword.fetch!(opts, :refund_address),
         {:ok, market} <- fetch_market(market_id),
         :ok <- ensure_active(market),
         :ok <- ensure_not_creator(market, account_id),
         contracts_subunits = AMM.to_subunits(contracts),
         {:ok, %{cost: cost_subunits, spread: spread_subunits, pool: _new_pool}} <-
           AMM.quote_breakdown(market.pool, side, contracts_subunits),
         {:ok, %{address: subaddress, address_index: index}} <- call_provider(provider) do
      amount_paid_piconeros = AMM.cost_to_piconeros(cost_subunits, market.unit_size)
      spread_piconeros = AMM.cost_to_piconeros(spread_subunits, market.unit_size)
      now = DateTime.utc_now()

      quote =
        Quote.new(
          market_id: market.id,
          account_id: account_id,
          side: side,
          contracts: contracts,
          amount_paid_piconeros: amount_paid_piconeros,
          spread_piconeros: spread_piconeros,
          subaddress: subaddress,
          subaddress_index: index,
          refund_address: refund_address,
          expires_at: DateTime.add(now, expires_in, :second)
        )

      with :ok <- Store.put_quote(quote) do
        EventBus.publish(%MarketsEvents.QuoteCreated{
          quote_id: quote.id,
          market_id: market.id,
          account_id: account_id,
          side: side,
          contracts: contracts,
          amount_paid_piconeros: amount_paid_piconeros,
          subaddress: subaddress,
          expires_at: quote.expires_at,
          timestamp: now
        })

        {:ok, quote}
      end
    end
  end

  @doc """
  Fills a Quote into a Position. Called by the Monero deposit
  poller when a transfer to a known subaddress reaches the
  confirmation threshold.

  At fill time the AMM is consulted again with the *current* pool.
  If the quote's locked-in `amount_paid_piconeros` still covers the
  current cost of `contracts` shares, we fill at the locked amount
  and apply the new pool. Otherwise the quote is rejected with
  `{:error, :price_moved}` — the caller (Poller) is responsible for
  scheduling a refund.

  Atomic across three rows: the market's AMM update, the new
  Position, and removal of the consumed Quote — single WAL append
  via `Store.put_fill/3`. Reservation stays atomic with the AMM
  update.

  ## Options

  - `:deposit_txid` — on-chain transaction id, recorded on the
    QuoteFilled event for audit. Optional.

  ## Errors

  - `:quote_not_found`
  - `:quote_expired`
  - `:market_not_found`
  - `:market_not_active`
  - `:insufficient_liquidity` — pool can no longer support `contracts`
  - `:price_moved` — current AMM cost exceeds locked amount
  """
  @spec fill_quote(binary(), keyword()) ::
          {:ok, Position.t()}
          | {:error,
             :quote_not_found
             | :quote_expired
             | :market_not_found
             | :market_not_active
             | :insufficient_liquidity
             | :price_moved}
  def fill_quote(quote_id, opts \\ []) when is_binary(quote_id) do
    Guards.ensure_operational!()

    # Capture `now` once at function entry. All expiry checks inside
    # this call must compare against this single timepoint — otherwise
    # a quote that's unexpired at the start can fill against a state
    # where it's expired by the time we reach Store.put_fill.
    now = DateTime.utc_now()

    with {:ok, quote} <- fetch_quote(quote_id),
         :ok <- ensure_unexpired(quote, now),
         {:ok, market} <- fetch_market(quote.market_id),
         :ok <- ensure_active(market),
         contracts_subunits = AMM.to_subunits(quote.contracts),
         {:ok, cost_subunits, new_pool} <-
           AMM.quote(market.pool, quote.side, contracts_subunits),
         :ok <- ensure_price_locked(cost_subunits, market.unit_size, quote),
         {:ok, updated_market} <- Market.update_pool(market, new_pool) do
      # Spread is locked at quote time, not re-derived here — the
      # user already paid this amount and the federation custody
      # is owed it regardless of how the pool moved between quote
      # and fill.
      position =
        Position.new(
          market.id,
          quote.account_id,
          quote.side,
          quote.contracts,
          quote.amount_paid_piconeros,
          quote.spread_piconeros
        )

      # CAS on pre-fill snapshot: refuses if the market's pool or
      # status has moved since the fetch — e.g. Scheduler's expire
      # committed between fetch_market and put_fill, or a concurrent
      # fill wrote first.
      expected = %{pool: market.pool, status: market.status}

      with :ok <-
             Store.put_fill(updated_market, position, quote.id, expected,
               deposit_txid: Keyword.get(opts, :deposit_txid)
             ) do
        EventBus.publish(%MarketsEvents.QuoteFilled{
          quote_id: quote.id,
          position_id: position.id,
          market_id: market.id,
          account_id: quote.account_id,
          side: quote.side,
          contracts: quote.contracts,
          amount_paid_piconeros: quote.amount_paid_piconeros,
          deposit_txid: Keyword.get(opts, :deposit_txid),
          timestamp: DateTime.utc_now()
        })

        {:ok, position}
      end
    end
  end

  # --- Internal ---

  # `place_position/4` is a payment-free position mint — the payer
  # of record is never established, no deposit txid is bound. Real
  # user traffic flows through `create_quote/5` + `fill_quote/2`
  # which threads a Monero deposit through the pipeline. The direct
  # mint exists only for tests that need to seed positions without
  # standing up a full quote-and-poller flow. Refuse in prod so a
  # future accidental HTTP wiring can't mint free positions.
  defp refuse_in_prod! do
    if Application.get_env(:perpwalk, :env) == :prod do
      raise "Trader.place_position/4 is test-only — use create_quote + fill_quote in production"
    end

    :ok
  end

  defp fetch_quote(quote_id) do
    case Store.get_quote(quote_id) do
      {:ok, quote} -> {:ok, quote}
      {:error, :not_found} -> {:error, :quote_not_found}
    end
  end

  defp ensure_unexpired(%Quote{} = quote, %DateTime{} = now) do
    if Quote.expired?(quote, now) do
      {:error, :quote_expired}
    else
      :ok
    end
  end

  defp ensure_price_locked(cost_subunits, unit_size, %Quote{} = quote) do
    current_cost_piconeros = AMM.cost_to_piconeros(cost_subunits, unit_size)

    if current_cost_piconeros <= quote.amount_paid_piconeros do
      :ok
    else
      {:error, :price_moved}
    end
  end

  defp fetch_market(market_id) do
    case Store.get_market(market_id) do
      {:ok, market} -> {:ok, market}
      {:error, :not_found} -> {:error, :market_not_found}
    end
  end

  defp ensure_active(%Market{status: :active}), do: :ok
  defp ensure_active(_market), do: {:error, :market_not_active}

  # Refund address is required per-quote — captured from the user at
  # trade time so that underpayment / overpayment / voided-market
  # scenarios can push funds back to a known destination without any
  # out-of-band operator contact. Validation matches `Federation.Rules`
  # destination_sanity so refund and payout use the same address filter.
  defp ensure_refund_address(nil), do: {:error, :refund_address_required}
  defp ensure_refund_address(""), do: {:error, :refund_address_required}

  defp ensure_refund_address(addr) when is_binary(addr) do
    if MoneroAddress.valid?(addr),
      do: :ok,
      else: {:error, :refund_address_invalid}
  end

  defp ensure_refund_address(_other), do: {:error, :refund_address_invalid}

  # Voter and Disputer forbid self-action on the creator's own market
  # with the same shape; trading deserves the same asymmetry. The
  # creator already has economic exposure through the LP seed
  # (residual at settlement, full deposit on void) plus the 1/6
  # share of trade spread — both are symmetric and outcome-independent.
  # Directional trading on top would compound a private-information
  # edge (creator authored the resolution criteria, can see private
  # signals about the outcome, has procedural authority as the
  # resolver) into a conflict-of-interest pathway the dispute
  # mechanism alone can't reliably catch. Cleanly separating "LP +
  # spread share" exposure from "directional bet on outcome" exposure
  # keeps the resolution mechanism trustworthy.
  defp ensure_not_creator(market, account_id) do
    if Market.creator?(market, account_id),
      do: {:error, :creator_cannot_trade_own_market},
      else: :ok
  end

  defp call_provider(provider) when is_function(provider, 0) do
    case provider.() do
      {:ok, %{address: _, address_index: _}} = ok -> ok
      {:error, reason} -> {:error, {:subaddress_provider_failed, reason}}
      other -> {:error, {:subaddress_provider_failed, other}}
    end
  rescue
    e -> {:error, {:subaddress_provider_failed, e}}
  catch
    :exit, reason -> {:error, {:subaddress_provider_failed, reason}}
  end

  # Accept either a 0-arity function or a `{Module, :function, args}`
  # MFA tuple (the config-friendly form).
  defp normalize_provider(fun) when is_function(fun, 0), do: fun

  defp normalize_provider({mod, fun, args})
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    fn -> apply(mod, fun, args) end
  end
end
