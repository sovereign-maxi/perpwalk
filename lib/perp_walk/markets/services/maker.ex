defmodule PerpWalk.Markets.Services.Maker do
  @moduledoc """
  Creates new markets and confirms initial liquidity deposits.

  Market creation is a two-step flow:

  1. `create_market/1` — allocates a Monero subaddress for the
     creator's initial liquidity, persists the market in
     `:awaiting_deposit`, publishes `MarketCreated`. The creator
     must send `deposit_amount` piconeros to the returned
     subaddress.
  2. `confirm_deposit/2` — called once the deposit has confirmed
     on-chain (typically by `PerpWalk.Monero.Poller`). Transitions
     the market to `:pending` and publishes `MarketDepositConfirmed`.
     The listing-window scan in `Markets.Scheduler` then progresses
     `:pending → :active` per the existing flow.

  ## Initial liquidity (formerly "creation bond")

  The creator's deposit IS the pool seed. With `deposit_amount` of
  real XMR collateral and `unit_size` per contract, the pool starts
  at `deposit_amount / unit_size` virtual contracts on EACH side.
  This is the standard Polymarket FPMM LP-seeding model: 1 unit of
  collateral splits 1:1 into 1 YES + 1 NO via conditional-tokens
  semantics, so `D` collateral produces `D / unit_size` of each.

  Under this model the creator is the market's sole LP. They earn a
  share of the spread on every trade, and at settlement their
  liquidity returns minus any losses to winning traders. If the
  community downvotes the market into `:rejected`, the liquidity
  burns to house revenue exactly as the bond did before — the
  skin-in-the-game gate is preserved. The operator never has to
  deploy capital under any outcome.

  The subaddress allocator is injectable via the `:subaddress_provider`
  option so callers can supply a stubbed generator — defaults to
  `Monero.Facade.create_subaddress/0`.
  """

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Guards
  alias PerpWalk.Markets.{AMM, Market, Store}
  alias PerpWalk.Monero.Facade, as: MoneroFacade

  # Operator dials. `:unit_size`, `:pool`, `:resolution_deadline` are
  # NEVER caller-tunable — they come from `:perpwalk, :markets` config
  # so a malicious LiveView, future API endpoint, or stale test fixture
  # can't shrink the unit size below the economically-meaningful floor,
  # forge a pool, or stall resolution indefinitely.
  #
  # `:deposit_amount` IS caller-tunable within operator-set bounds
  # (`min_deposit_piconeros` / `max_deposit_piconeros`). Creators
  # signal conviction level by depositing more, which grows the pool
  # depth and the volume the market can absorb before slippage. Unit
  # size stays fixed across all markets so a contract is always worth
  # the same amount — traders build one mental model.
  #
  # Default 1 XMR deposit at 0.01 XMR unit size = 100 contracts of LP
  # depth per side (stored as 100_000 subunits per side after AMM
  # scaling — see `AMM` moduledoc). Larger deposits derive
  # proportionally larger initial contract counts.
  @default_min_deposit_piconeros 1_000_000_000_000
  @default_max_deposit_piconeros 100_000_000_000_000
  @default_unit_size_piconeros 10_000_000_000

  # Form-facing deposit granularity — the increment creators pick their
  # deposit in. Independent of `unit_size_piconeros` (the AMM contract
  # cost); the AMM stays fine-grained so a 5 XMR deposit yields 500
  # contracts of depth (not 5), keeping slippage sane at the curve
  # extremes. deposit_step must always be a multiple of unit_size —
  # `ensure_deposit_divides_step` + `ensure_deposit_divides_unit`
  # catch any misconfiguration at market-creation time.
  @default_deposit_step_piconeros 1_000_000_000_000

  @default_resolution_window_seconds 86_400

  @disallowed_caller_opts [:unit_size, :pool, :resolution_deadline]

  @doc """
  Creates a market and persists it in `:awaiting_deposit`. Allocates a
  Monero subaddress that the creator must fund with the configured
  creation deposit before the market progresses to `:pending`.

  Required caller opts:

  - `:description`, `:resolution_criterion`, `:category`
  - `:expiry`
  - `:creator_account_id`

  Optional:

  - `:subaddress_provider` — 0-arity fun returning
    `{:ok, %{address: address, address_index: idx}} | {:error, term()}`.
    Defaults to `MoneroFacade.create_subaddress/0`. Tests inject a
    stub via `Application.put_env(:perpwalk, :subaddress_provider, ...)`.
  - `:deposit_amount` — creator-tunable LP deposit in piconeros, bounded
    by `min_deposit_piconeros` / `max_deposit_piconeros` config. Falls
    back to `min_deposit_piconeros` when omitted. Must be an exact
    multiple of `unit_size_piconeros` so the derived initial pool depth
    is integer.

  **Not accepted from caller:** `:unit_size`, `:pool`,
  `:resolution_deadline`. These are operator dials — set via
  `:perpwalk, :markets` config. The resolution deadline is derived
  from `expiry + resolution_window_seconds`. Passing any of these
  raises `ArgumentError`.

  Returns `{:ok, market}` or `{:error, reason}`. Deposit-bounds
  violations return `{:error, {:deposit_below_min, deposit, min}}`
  or `{:error, {:deposit_above_max, deposit, max}}`.
  """
  @spec create_market(keyword()) :: {:ok, Market.t()} | {:error, term()}
  def create_market(opts) do
    Guards.ensure_operational!()

    case Keyword.take(opts, @disallowed_caller_opts) do
      [] ->
        :ok

      rejected ->
        raise ArgumentError,
              "Maker.create_market/1 does not accept #{inspect(Keyword.keys(rejected))} — " <>
                "set via :perpwalk, :markets config"
    end

    expiry = Keyword.fetch!(opts, :expiry)
    deposit = Keyword.get(opts, :deposit_amount, min_deposit_piconeros())
    unit_size = unit_size_piconeros()
    deposit_step = deposit_step_piconeros()

    provider = resolve_subaddress_provider(opts)

    with :ok <- ensure_expiry_in_future(expiry),
         :ok <- ensure_deposit_within_bounds(deposit),
         :ok <- ensure_deposit_divides_step(deposit, deposit_step),
         :ok <- ensure_deposit_divides_unit(deposit, unit_size),
         resolution_deadline = DateTime.add(expiry, resolution_window_seconds(), :second),
         {:ok, %{address: address, address_index: index}} <- allocate_subaddress(provider),
         pool_depth_contracts = div(deposit, unit_size),
         pool_depth_subunits = AMM.to_subunits(pool_depth_contracts),
         opts_with_dials <-
           opts
           |> Keyword.put(:deposit_subaddress, address)
           |> Keyword.put(:deposit_subaddress_index, index)
           |> Keyword.put(:deposit_amount, deposit)
           |> Keyword.put(:unit_size, unit_size)
           |> Keyword.put(:pool, AMM.new(pool_depth_subunits, pool_depth_subunits))
           |> Keyword.put(:resolution_deadline, resolution_deadline),
         {:ok, market} <- Market.new(opts_with_dials),
         :ok <- Store.put_market(market) do
      EventBus.publish(%MarketsEvents.MarketCreated{
        market_id: market.id,
        description: market.description,
        category: market.category,
        creator_account_id: market.creator_account_id,
        timestamp: DateTime.utc_now()
      })

      {:ok, market}
    end
  end

  @doc """
  Marks a market's creation deposit as confirmed on-chain.
  Transitions `:awaiting_deposit → :pending`. Idempotent — calling
  on a market that's already past `:awaiting_deposit` returns
  `{:error, :invalid_transition}`.

  Called by `PerpWalk.Monero.Poller` once the deposit transaction
  reaches the configured confirmation count, or manually by the
  operator via `PerpWalk.Markets.Console`.
  """
  @spec confirm_deposit(binary()) :: {:ok, Market.t()} | {:error, atom()}
  def confirm_deposit(market_id) when is_binary(market_id) do
    Guards.ensure_operational!()

    with {:ok, market} <- fetch_market(market_id),
         {:ok, confirmed} <- Market.confirm_deposit(market),
         :ok <- Store.put_market_cas(confirmed, %{status: market.status}) do
      EventBus.publish(%MarketsEvents.MarketDepositConfirmed{
        market_id: confirmed.id,
        deposit_subaddress_index: confirmed.deposit_subaddress_index,
        timestamp: confirmed.deposit_confirmed_at
      })

      {:ok, confirmed}
    end
  end

  # --- Operator Dials ---

  @doc "Configured floor for creator deposits (piconeros)."
  @spec min_deposit_piconeros() :: pos_integer()
  def min_deposit_piconeros,
    do: get_config(:min_deposit_piconeros, @default_min_deposit_piconeros)

  @doc "Configured ceiling for creator deposits (piconeros)."
  @spec max_deposit_piconeros() :: pos_integer()
  def max_deposit_piconeros,
    do: get_config(:max_deposit_piconeros, @default_max_deposit_piconeros)

  @doc "Configured AMM unit size — deposit must be an exact multiple (piconeros)."
  @spec unit_size_piconeros() :: pos_integer()
  def unit_size_piconeros,
    do: get_config(:unit_size_piconeros, @default_unit_size_piconeros)

  @doc "Configured form-facing deposit granularity (piconeros). Independent of unit_size."
  @spec deposit_step_piconeros() :: pos_integer()
  def deposit_step_piconeros,
    do: get_config(:deposit_step_piconeros, @default_deposit_step_piconeros)

  # Caller-tunable deposit within operator-set bounds. Fails closed on
  # any deposit below min (spam floor) or above max (concentration
  # limit) — creators express conviction level via deposit size but
  # the operator keeps veto over the extremes via config.
  defp ensure_deposit_within_bounds(deposit) when is_integer(deposit) do
    min = min_deposit_piconeros()
    max = max_deposit_piconeros()

    cond do
      deposit < min -> {:error, {:deposit_below_min, deposit, min}}
      deposit > max -> {:error, {:deposit_above_max, deposit, max}}
      true -> :ok
    end
  end

  defp ensure_deposit_within_bounds(_other), do: {:error, :deposit_not_integer}

  # An already-past expiry yields a market whose resolution window
  # opens in the past — the resolver would immediately try to
  # settle/void a market that never traded. Refuse at the boundary.
  defp ensure_expiry_in_future(%DateTime{} = expiry) do
    if DateTime.after?(expiry, DateTime.utc_now()),
      do: :ok,
      else: {:error, :expiry_not_in_future}
  end

  defp ensure_expiry_in_future(_other), do: {:error, :expiry_not_datetime}

  # The creator's deposit IS the pool seed (LP-capital model); the
  # pool depth derives from `div(deposit, unit_size)`. A remainder
  # would leave a sliver of collateral unaccounted for at settlement,
  # so fail closed at the create boundary rather than silently
  # rounding.
  defp ensure_deposit_divides_unit(deposit, unit_size)
       when is_integer(deposit) and deposit > 0 and is_integer(unit_size) and unit_size > 0 do
    if rem(deposit, unit_size) == 0,
      do: :ok,
      else: {:error, {:deposit_not_unit_multiple, deposit, unit_size}}
  end

  # Misconfigured operator dials (non-integer / non-positive config)
  # must surface as error tuples, not FunctionClauseError crashes.
  defp ensure_deposit_divides_unit(_deposit, _unit_size),
    do: {:error, :invalid_unit_size_config}

  # Form-facing granularity — creators pick their deposit in whole
  # deposit_step units (mainnet: 1 XMR steps; stagenet: 0.01 XMR). This
  # is orthogonal to the AMM's unit_size and typically 100x coarser.
  # Both checks fire; both must pass. A misconfiguration where
  # deposit_step isn't a multiple of unit_size gets caught here.
  defp ensure_deposit_divides_step(deposit, deposit_step)
       when is_integer(deposit) and deposit > 0 and is_integer(deposit_step) and deposit_step > 0 do
    if rem(deposit, deposit_step) == 0,
      do: :ok,
      else: {:error, {:deposit_not_step_multiple, deposit, deposit_step}}
  end

  defp ensure_deposit_divides_step(_deposit, _deposit_step),
    do: {:error, :invalid_deposit_step_config}

  defp resolution_window_seconds,
    do: get_config(:resolution_window_seconds, @default_resolution_window_seconds)

  defp get_config(key, default) do
    :perpwalk |> Application.get_env(:markets, []) |> Keyword.get(key, default)
  end

  # --- Internal ---

  defp fetch_market(id) do
    case Store.get_market(id) do
      {:ok, market} -> {:ok, market}
      {:error, :not_found} -> {:error, :market_not_found}
    end
  end

  defp resolve_subaddress_provider(opts) do
    opts
    |> Keyword.get(
      :subaddress_provider,
      Application.get_env(:perpwalk, :subaddress_provider, &MoneroFacade.create_subaddress/0)
    )
    |> normalize_provider()
  end

  # Accept either a 0-arity function or a `{Module, :function, args}`
  # MFA tuple (config-friendly form — application env can't hold
  # function captures).
  defp normalize_provider(fun) when is_function(fun, 0), do: fun

  defp normalize_provider({mod, fun, args})
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    fn -> apply(mod, fun, args) end
  end

  defp allocate_subaddress(provider) when is_function(provider, 0) do
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
end
