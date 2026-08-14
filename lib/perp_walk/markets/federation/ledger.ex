defmodule PerpWalk.Markets.Federation.Ledger do
  @moduledoc """
  Federation revenue ledger for the Markets bounded context.

  Three sources contribute to federation revenue:

  - **Slashed dispute stakes** — when a dispute resolves
    `:resolved_for` (the creator's resolution stood, the disputer
    was wrong), a configurable percentage of the disputer's stake
    is forfeited and accrues to the federation.
  - **Forfeited creator liquidity** — when a market is community-
    rejected (downvoted past the burn threshold), the creator's
    deposit is forfeited rather than refunded. **Activated
    markets** (`:settled` or `:voided`) do NOT contribute — under
    the LP-capital model the creator's deposit IS the pool seed
    and returns to the creator via `:creator_lp_return` at
    settlement (minus losses to winning traders) or void (in full).
  - **Trade spread** — every position records the 1.5% spread
    captured by the AMM at quote time. At settlement the accumulated
    spread splits into a 1.25% federation share and a 0.25% creator
    share.

  This module derives **earned** totals — the running tally of
  income the federation has accumulated. Actual fund movement
  (sweeping federation revenue to a wallet) goes through the
  regular `Federation.Facade.enqueue_payout` 2-of-3 signing
  pipeline.

  ## Counter-backed reads

  The Markets store maintains incremental counters on each
  qualifying state transition (slash on `:resolved_for`, burn on
  `:rejected`, settle count + spread on `:settled`). `breakdown/0`
  reads those counters in O(1). The previous derivation walked the
  status indexes on every call — fine in steady state but quadratic
  in cumulative cost when called per-tick under accumulating
  state. WAL replay rebuilds the counters because replay funnels
  through the same `insert_*` helpers as live writes.

  ## Drift detection

  `reconcile/0` cross-checks the counter values against a fresh
  index-derivation. Available for periodic integrity checks.
  Returns `:ok` when the two agree, or `{:error, mismatches}` when
  they don't.

  Naming note: this is the Markets-domain *view* of the federation's
  revenue. It is distinct from the top-level `PerpWalk.Federation`
  bounded context (which owns the multisig signing infrastructure).
  Same federation as the architectural entity, different concerns.
  """

  require Logger

  alias PerpWalk.Markets.{Dispute, Market, Position, Store}

  # Per-trade AMM spread is 1.5% of the fair cost (see Markets.AMM
  # moduledoc). At settlement the accumulated spread splits into a
  # 1.25% federation share and a 0.25% creator share. Encoded as an
  # integer 5:1 ratio (over a total of 6) so the split is exact in
  # piconero space without ppm arithmetic — 1.25 / 1.5 = 5/6 and
  # 0.25 / 1.5 = 1/6 of the captured spread.
  #
  # Floor division means up to 5 piconeros per settled market may be
  # left unattributed when `spread_total` is not divisible by 6. The
  # remainder stays in the multisig wallet, so the wallet balance
  # will be marginally above `federation_spread + creator_spread`
  # cumulatively — drift is in the operator's favour. Intentional;
  # the alternative is a third "rounding" counter for sub-piconero
  # accounting which is not worth the bookkeeping cost.
  @federation_share_num 5
  @creator_share_num 1
  @share_denom 6

  @type breakdown :: %{
          total_piconeros: non_neg_integer(),
          slashed_piconeros: non_neg_integer(),
          burned_piconeros: non_neg_integer(),
          spread_total_piconeros: non_neg_integer(),
          federation_spread_piconeros: non_neg_integer(),
          creator_spread_piconeros: non_neg_integer(),
          slash_count: non_neg_integer(),
          burn_count: non_neg_integer(),
          settled_market_count: non_neg_integer()
        }

  @doc """
  Returns the cumulative federation-revenue breakdown across slashed
  dispute stakes, forfeited creator deposits, and trade-spread
  collected on settled markets.

  Spread from open / resolving / voided / refunded markets is NOT
  counted — only `:settled` markets have realised the spread as
  federation income. Voided markets refund traders fully (including
  the spread component); the AMM doc commits to that.
  """
  @spec breakdown() :: breakdown()
  def breakdown do
    counters = Store.ledger_counters()

    slashed = counters.slashed_piconeros
    burned = counters.burned_piconeros
    spread_total = counters.spread_total_piconeros

    federation_spread = div(spread_total * @federation_share_num, @share_denom)
    creator_spread = div(spread_total * @creator_share_num, @share_denom)

    %{
      total_piconeros: slashed + burned + federation_spread,
      slashed_piconeros: slashed,
      burned_piconeros: burned,
      spread_total_piconeros: spread_total,
      federation_spread_piconeros: federation_spread,
      creator_spread_piconeros: creator_spread,
      slash_count: counters.slash_count,
      burn_count: counters.burn_count,
      settled_market_count: counters.settled_market_count
    }
  end

  @doc "Cumulative federation revenue (slash + burn + 5/6 of spread) in piconeros."
  @spec total_piconeros() :: non_neg_integer()
  def total_piconeros do
    %{total_piconeros: total} = breakdown()
    total
  end

  @doc """
  Withdrawable balance — same shape as `total_piconeros/0` minus any
  payouts already claimed against this revenue. The federation
  withdrawal flow consumes this through the rules engine.
  """
  @spec withdrawable_piconeros() :: non_neg_integer()
  def withdrawable_piconeros do
    earned = total_piconeros()
    drawn = PerpWalk.Federation.Facade.federation_income_drawn()

    if drawn > earned do
      # drawn > earned means a federation_income payout was sized and
      # signed against a withdrawable balance that the live counter no
      # longer reports — either a counter-maintenance bug or genuine
      # accounting drift. Surface loudly; the silent clamp below
      # preserves availability but hides the signal. Reconciliation
      # belongs to `reconcile/0` and operator review.
      Logger.error(
        "Ledger: withdrawable_piconeros clamped — drawn exceeds earned, " <>
          "earned=#{earned}, drawn=#{drawn}"
      )
    end

    max(0, earned - drawn)
  end

  @type mismatch :: %{
          key: atom(),
          counter: non_neg_integer(),
          derived: non_neg_integer()
        }

  @doc """
  Cross-checks the live counter values against a fresh derivation
  from the status indexes. Useful after restart and as a periodic
  integrity probe. The derivation re-walks the indexes the
  way the pre-counter implementation did, so a mismatch means
  either a counter-maintenance bug or genuine accounting drift.

  Returns `:ok` on agreement or `{:error, [mismatch()]}` with one
  entry per disagreeing field.
  """
  @spec reconcile() :: :ok | {:error, [mismatch()]}
  def reconcile do
    counters = Store.ledger_counters()
    derived = derive_from_indexes()

    mismatches =
      for key <- [
            :slashed_piconeros,
            :burned_piconeros,
            :spread_total_piconeros,
            :slash_count,
            :burn_count,
            :settled_market_count
          ],
          Map.get(counters, key) != Map.get(derived, key),
          do: %{key: key, counter: Map.get(counters, key), derived: Map.get(derived, key)}

    case mismatches do
      [] -> :ok
      _ -> {:error, mismatches}
    end
  end

  # --- Internal ---

  # The pre-counter derivation, retained as the reconciliation
  # source of truth. Walks the status indexes once and folds.
  defp derive_from_indexes do
    rejected_markets = Store.list_markets_by_status(:rejected)
    settled_markets = Store.list_markets_by_status(:settled)

    slashed_disputes =
      [:resolved_for, :refunded_partial]
      |> Enum.flat_map(&Store.list_disputes_by_status/1)
      |> Enum.filter(&Dispute.slashed?/1)

    {slashed, slash_count} =
      Enum.reduce(slashed_disputes, {0, 0}, fn d, {sum, count} ->
        {sum + d.slashed_amount_piconeros, count + 1}
      end)

    {burned, burn_count} = burn_totals(rejected_markets)
    spread_total = spread_total_for_settled(settled_markets)

    %{
      slashed_piconeros: slashed,
      burned_piconeros: burned,
      spread_total_piconeros: spread_total,
      slash_count: slash_count,
      burn_count: burn_count,
      settled_market_count: length(settled_markets)
    }
  end

  defp burn_totals(rejected_markets) do
    Enum.reduce(rejected_markets, {0, 0}, fn m, {sum, count} ->
      {sum + m.deposit_amount, count + 1}
    end)
  end

  defp spread_total_for_settled(settled_markets) do
    Enum.reduce(settled_markets, 0, fn %Market{id: id}, acc ->
      id
      |> Store.list_positions_for_market()
      |> Enum.reduce(acc, fn %Position{spread_piconeros: s}, inner ->
        inner + (s || 0)
      end)
    end)
  end
end
