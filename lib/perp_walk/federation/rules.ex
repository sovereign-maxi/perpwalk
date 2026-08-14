defmodule PerpWalk.Federation.Rules do
  @moduledoc """
  Pure deterministic rule engine for federation payout signing.

  Given a Payout plus the relevant Markets state and recent
  request history, returns `:ok` if the request is eligible for
  auto-signing or `{:reject, reason}` otherwise. **No I/O, no
  GenServer calls, no time-of-day branches** — every input is
  passed into `evaluate/1` so each guardian produces the same
  verdict on the same data.

  ## Rule order

  Rules run in fail-fast order — the first rejection wins. The
  ordering is deliberate: cheap and authoritative checks first
  (amount/status sanity), then policy gates (rate caps, cooldown).

      1. `amount_match`        — amount_piconeros equals
                                  Markets.position_payout/2
      2. `position_status`     — position is :settled_winner or
                                  :refunded (not :open, :paid_out, etc.)
      3. `market_status`       — market is :settled / :voided
      4. `destination_sanity`  — destination has plausible Monero
                                  address format
      5. `cooldown_threshold`  — large payouts wait the configured
                                  cooldown so operator can spot
                                  anomalies before auto-sign
      6. `rate_cap_global`     — sum of recent in-flight + completed
                                  requests within an hour ≤ threshold

  Operator override (`Federation.Console.force_sign/1`) clears a
  request's status from `:awaiting_operator` to `:rules_passed`,
  but the next Signer tick still re-evaluates rules before signing
  (fail-closed posture: underlying Markets/Federation state may
  have changed since the original rejection, and the operator's
  intent is "I have reviewed this request and want it signed if
  it's currently safe", not "sign it unconditionally"). If the
  re-evaluation rejects, the request transitions to `:failed`
  (terminal) and emits `PayoutFailed` with a `rules_revalidation`
  reason. Terminal because a stuck `:rules_passed` would phantom-
  reserve balance in the federation income ledger (which sums all
  non-`:failed` requests as `drawn`); the operator can enqueue a
  fresh request if they want to retry once state changes.
  """

  alias PerpWalk.Federation.Payout
  alias PerpWalk.Markets.{Dispute, Market, Position}
  alias PerpWalk.Markets.Facade, as: Markets
  alias PerpWalk.Markets.Quote, as: MarketsQuote
  alias PerpWalk.Markets.Services.Cashier
  alias PerpWalk.Monero.Address

  @type rule_result :: :ok | {:reject, String.t()}

  @type context :: %{
          required(:request) => Payout.t(),
          required(:position) => Position.t() | nil,
          required(:market) => Market.t(),
          required(:now) => DateTime.t(),
          optional(:dispute) => Dispute.t() | nil,
          optional(:recent_requests) => [Payout.t()],
          optional(:config) => keyword(),
          optional(:withdrawable_piconeros) => non_neg_integer()
        }

  # --- Defaults ---

  @default_rate_cap_global_piconeros 100 * 1_000_000_000_000
  @default_cooldown_threshold_piconeros 10 * 1_000_000_000_000
  @default_cooldown_seconds 600
  @default_window_seconds 3_600

  # --- Public API ---

  @doc """
  Evaluates the request against every rule and returns the first
  rejection, or `:ok` if every rule passes.
  """
  @spec evaluate(context()) :: rule_result()
  def evaluate(%{} = ctx) do
    ctx = Map.put_new(ctx, :recent_requests, [])
    ctx = Map.put_new(ctx, :config, [])

    [
      &amount_match/1,
      &position_status/1,
      &market_status/1,
      &destination_sanity/1,
      &cooldown_threshold/1,
      &rate_cap_global/1
    ]
    |> Enum.reduce_while(:ok, fn rule, _acc ->
      case rule.(ctx) do
        :ok -> {:cont, :ok}
        {:reject, _} = err -> {:halt, err}
      end
    end)
  end

  # --- Individual Rules ---

  @doc false
  def amount_match(%{request: %Payout{kind: kind} = req} = ctx)
      when kind in [:dispute_refund_full, :dispute_refund_partial] do
    case fetch_dispute(ctx, req) do
      {:ok, dispute} ->
        expected = Dispute.refund_amount_piconeros(dispute)

        if req.amount_piconeros == expected do
          :ok
        else
          {:reject,
           "amount_match: requested #{req.amount_piconeros}, expected #{expected} from Dispute.refund_amount_piconeros/1"}
        end

      :error ->
        {:reject, "amount_match: dispute not found for refund request #{req.id}"}
    end
  end

  def amount_match(%{request: %Payout{kind: :federation_income, amount_piconeros: requested}} = ctx) do
    # Federation income withdrawal: clamp to the withdrawable ledger
    # balance carried in ctx. The caller (Signer.load_context/3)
    # reads the live ledger once before calling evaluate/1 so this
    # module stays a pure deterministic function over its inputs.
    #
    # `available = earned - drawn` where `drawn` INCLUDES the pending
    # request being evaluated. That arithmetic implicitly caps any
    # single withdrawal to ~half the remaining balance — a compromised
    # iex session or misconfigured script can drain at most 50% per
    # call; a full drain takes multiple sequential withdrawals. See
    # `project_perp_walk_income_half_cap` memory.
    available =
      Map.get_lazy(ctx, :withdrawable_piconeros, fn ->
        PerpWalk.Markets.Federation.Ledger.withdrawable_piconeros()
      end)

    cond do
      requested <= 0 ->
        {:reject, "amount_match: federation_income requires positive amount, got #{requested}"}

      requested > available ->
        {:reject, "amount_match: federation_income requested #{requested} exceeds withdrawable balance #{available}"}

      true ->
        :ok
    end
  end

  def amount_match(%{
        request: %Payout{kind: :creator_lp_return, amount_piconeros: requested},
        market: market
      }) do
    case creator_lp_expected_amount(market) do
      {:ok, expected} ->
        if requested == expected do
          :ok
        else
          {:reject,
           "amount_match: creator_lp_return requested #{requested}, expected #{expected} " <>
             "from market.pool / deposit_amount"}
        end

      {:error, reason} ->
        {:reject, "amount_match: creator_lp_return rejected — #{reason}"}
    end
  end

  # Quote-underpayment refund: exact on-chain amount can't be
  # re-derived from Markets state (the Poller observed it), so we
  # bound-check instead — the refund must be positive and no larger
  # than the quote's locked price. A poller bug or malicious cluster
  # write asking for more than the user could plausibly have deposited
  # is refused here rather than at signing time.
  def amount_match(%{
        request:
          %Payout{
            kind: :quote_underpayment_refund,
            amount_piconeros: requested,
            source_quote_id: quote_id
          } = req
      })
      when is_binary(quote_id) do
    case Markets.get_quote(quote_id) do
      {:ok, %MarketsQuote{amount_paid_piconeros: expected}} ->
        cond do
          requested <= 0 ->
            {:reject, "amount_match: quote_underpayment_refund requires positive amount, got #{requested}"}

          requested > expected ->
            {:reject, "amount_match: quote_underpayment_refund #{requested} exceeds locked quote price #{expected}"}

          true ->
            :ok
        end

      _ ->
        {:reject, "amount_match: source quote #{quote_id} not found for refund request #{req.id}"}
    end
  end

  def amount_match(%{
        request: %Payout{amount_piconeros: requested},
        position: position,
        market: market
      }) do
    expected = Markets.position_payout(position, market.unit_size)

    if requested == expected do
      :ok
    else
      {:reject, "amount_match: requested #{requested}, expected #{expected} from Markets.position_payout/2"}
    end
  end

  # Expected residual = winning-side pool reserve × unit_size PLUS
  # the creator's 1/6 share of accumulated trade-spread. Pre-fix
  # the spread share was computed in
  # `Markets.Federation.Ledger.breakdown/0` and documented as paid
  # via the LP return, but this rule excluded it — every payout
  # matching the pool-only amount, every payout including the
  # spread share rejected. The share accumulated unattributed in
  # the multisig. Now included so the operator's enqueue matches.
  #
  # Voided markets have no trades filled and no spread accumulator,
  # so they return `deposit_amount` unchanged.
  defp creator_lp_expected_amount(%Market{
         status: :settled,
         outcome: :yes,
         pool: pool,
         unit_size: u,
         id: id
       })
       when is_integer(u) and u > 0 do
    {:ok, Markets.subunits_to_piconeros(pool.yes, u) + Cashier.creator_spread_share(id)}
  end

  defp creator_lp_expected_amount(%Market{
         status: :settled,
         outcome: :no,
         pool: pool,
         unit_size: u,
         id: id
       })
       when is_integer(u) and u > 0 do
    {:ok, Markets.subunits_to_piconeros(pool.no, u) + Cashier.creator_spread_share(id)}
  end

  defp creator_lp_expected_amount(%Market{status: :voided, deposit_amount: deposit})
       when is_integer(deposit) and deposit > 0 do
    {:ok, deposit}
  end

  defp creator_lp_expected_amount(%Market{status: status, outcome: outcome}) do
    {:error,
     "creator_lp_return requires :settled with :yes / :no outcome or :voided, " <>
       "got status=#{inspect(status)} outcome=#{inspect(outcome)}"}
  end

  @doc false
  def position_status(%{request: %Payout{kind: kind}})
      when kind in [
             :dispute_refund_full,
             :dispute_refund_partial,
             :federation_income,
             :creator_lp_return,
             :quote_underpayment_refund
           ] do
    :ok
  end

  def position_status(%{request: %Payout{kind: :winner_payout}, position: position}) do
    if position.status == :settled_winner do
      :ok
    else
      {:reject, "position_status: winner_payout requires :settled_winner, got #{inspect(position.status)}"}
    end
  end

  def position_status(%{request: %Payout{kind: :refund}, position: position}) do
    if position.status == :refunded do
      :ok
    else
      {:reject, "position_status: refund requires :refunded, got #{inspect(position.status)}"}
    end
  end

  @doc false
  # Dispute refunds are decoupled from market settlement — guardians
  # may resolve a dispute via reverse_resolution / acknowledge_disputes
  # while the market itself is still :resolving. The disputer should
  # be able to reclaim funds as soon as their dispute lifecycle
  # terminates, regardless of whether the market has settled.
  def market_status(%{request: %Payout{kind: :dispute_refund_full}, market: market}) do
    if market.status in [:resolving, :settled, :voided] do
      :ok
    else
      {:reject,
       "market_status: dispute_refund_full requires :resolving / :settled / :voided market, got #{inspect(market.status)}"}
    end
  end

  def market_status(%{request: %Payout{kind: :dispute_refund_partial}, market: market}) do
    if market.status in [:resolving, :settled, :voided] do
      :ok
    else
      {:reject,
       "market_status: dispute_refund_partial requires :resolving / :settled / :voided market, got #{inspect(market.status)}"}
    end
  end

  def market_status(%{request: %Payout{kind: :winner_payout}, market: market}) do
    if market.status == :settled do
      :ok
    else
      {:reject, "market_status: winner_payout requires :settled market, got #{inspect(market.status)}"}
    end
  end

  # Federation income withdrawal isn't tied to a specific market —
  # it sweeps revenue accumulated across all settled markets. Pass
  # without a market.status check.
  def market_status(%{request: %Payout{kind: :federation_income}}), do: :ok

  # Quote-underpayment refunds are independent of market state — a
  # market that settled or voided between deposit and refund enqueue
  # doesn't affect our obligation to return the underpaid funds to
  # the address the user typed at quote-generation time.
  def market_status(%{request: %Payout{kind: :quote_underpayment_refund}}), do: :ok

  def market_status(%{request: %Payout{kind: :refund}, market: market}) do
    if market.status == :voided do
      :ok
    else
      {:reject, "market_status: refund requires :voided market, got #{inspect(market.status)}"}
    end
  end

  def market_status(%{request: %Payout{kind: :creator_lp_return}, market: market}) do
    cond do
      market.status not in [:settled, :voided] ->
        {:reject, "market_status: creator_lp_return requires :settled / :voided market, got #{inspect(market.status)}"}

      not is_nil(market.creator_lp_paid_out_at) ->
        # Signing-time backstop against duplicate LP-return payouts:
        # positions flip to :paid_out and disputes derive expected=0
        # once refunded, so their duplicates reject here — the LP
        # return has no such guard without reading the stamp.
        {:reject, "market_status: creator LP return already paid out (creator_lp_paid_out_at set)"}

      true ->
        :ok
    end
  end

  @doc false
  def destination_sanity(%{request: %Payout{destination: dest}}) do
    cond do
      not is_binary(dest) ->
        {:reject, "destination_sanity: destination must be a string"}

      byte_size(dest) > Address.max_input_length() ->
        {:reject,
         "destination_sanity: destination too long (#{byte_size(dest)} bytes; max #{Address.max_input_length()})"}

      not Address.valid?(dest) ->
        {:reject, "destination_sanity: destination is not a well-formed Monero address"}

      true ->
        :ok
    end
  end

  @doc false
  def cooldown_threshold(ctx) do
    config = ctx.config
    threshold = config_value(config, :cooldown_threshold_piconeros, @default_cooldown_threshold_piconeros)
    cooldown = config_value(config, :cooldown_seconds, @default_cooldown_seconds)

    if ctx.request.amount_piconeros < threshold do
      :ok
    else
      age = DateTime.diff(ctx.now, ctx.request.created_at, :second)

      if age >= cooldown do
        :ok
      else
        {:reject,
         "cooldown_threshold: amount #{ctx.request.amount_piconeros} ≥ threshold #{threshold} requires age ≥ #{cooldown}s, currently #{age}s"}
      end
    end
  end

  @doc false
  def rate_cap_global(ctx) do
    cap = config_value(ctx.config, :rate_cap_global_piconeros, @default_rate_cap_global_piconeros)
    window = config_value(ctx.config, :rate_window_seconds, @default_window_seconds)

    recent_total =
      ctx.recent_requests
      |> within_window(ctx.now, window)
      |> Enum.filter(&counted_against_rate?/1)
      |> Enum.map(& &1.amount_piconeros)
      |> Enum.sum()

    projected = recent_total + ctx.request.amount_piconeros

    if projected <= cap do
      :ok
    else
      {:reject, "rate_cap_global: projected #{projected} exceeds cap #{cap} in last #{window}s window"}
    end
  end

  # --- Helpers ---

  defp config_value(config, key, default) do
    Keyword.get(config, key, default)
  end

  defp within_window(requests, now, window_seconds) do
    cutoff = DateTime.add(now, -window_seconds, :second)
    Enum.filter(requests, fn req -> DateTime.compare(req.updated_at, cutoff) != :lt end)
  end

  # Count requests that have actually moved or are about to.
  # :pending and :rules_passed haven't drained the wallet yet, but
  # we count them anyway so a flood of pending requests can't
  # collectively exceed the cap once they all clear at once.
  defp counted_against_rate?(%Payout{status: :failed}), do: false
  defp counted_against_rate?(%Payout{}), do: true

  # Disputes aren't carried in the rule context — fetch via the
  # Markets read API. Pure module contract preserved (no GenServer
  # writes; just an :ets lookup that's deterministic per node).
  defp fetch_dispute(ctx, %Payout{} = req) do
    case Map.get(ctx, :dispute) do
      %Dispute{} = d ->
        {:ok, d}

      _ ->
        case Markets.get_dispute(req.account_id, req.market_id) do
          {:ok, d} -> {:ok, d}
          _ -> :error
        end
    end
  end
end
