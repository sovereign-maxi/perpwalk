defmodule PerpWalk.Reserves.Source do
  @moduledoc """
  `Vault.Source` implementation for PERP WALK.

  Each proof cycle, `Vault.Generator` calls these callbacks to capture
  a snapshot. This module bridges PERP WALK's domain state (positions,
  markets, federation multisig wallet balance) into the Vault contract.

  ## Liability derivation

  PERP WALK liability is derivative state — there are no discrete
  mint/burn events to drive running counters. Each proof cycle
  recomputes the worst-case payout obligation from the current
  position table, **grouped per market**:

  - `:open`           → contribute to YES-side or NO-side totals.
                        For markets in `:active` / `:expired` /
                        `:resolving` (outcome unknown), the market's
                        worst-case payout is
                        `max(open_yes + pool.yes_pic, open_no + pool.no_pic)`
                        because under either outcome the winning-side
                        trader payouts AND the creator's residual pool
                        on that side both fall due. Under conditional-
                        token AMM invariants those two sums are equal,
                        so the `max` is mostly a safety belt.
  - `:settled_winner` → `contracts * unit_size` (winner; payout owed)
  - `:refunded`       → `amount_paid` (refund owed)
  - `:settled_loser`  → 0
  - `:paid_out`       → 0 (already paid out)

  The earlier formula did `max(open_yes, open_no)` alone, which
  ignored the creator's residual pool share. That undercounted
  by `pool.<winner>_pic` per active market — a market with 1.3 XMR
  collected and only 0.5 XMR in trader-side open positions would
  publish 0.5 XMR outstanding while the true worst-case payout was
  closer to 1.29 XMR. Ratios looked artificially high.

  For settled / voided markets the pool residual is already counted
  via `creator_outstanding_for/1` (winning side's residual on settled,
  full deposit on void), so it does not double-count here.

  ## Unit translation

  Vault's `Source` callbacks return integer atomic units in plain
  maps (`:total_held`, `:outstanding`, etc.) — Vault itself is
  unit-agnostic. PERP WALK is piconero-denominated. The integer
  math is identical; only the suffix is unit-specific. The PERP WALK
  Facade re-exposes these values with `_piconeros` suffix at the
  public boundary via `PerpWalk.Reserves.Snapshot.to_piconeros/1`.

  ## Liabilities also covered

  - Dispute stakes pending refund — disputes in `:resolved_for` /
    `:resolved_against` whose refund payout has not landed yet still
    owe the disputer their `refund_amount_piconeros`.
  - Creator deposits awaiting return on voided markets — `:voided`
    markets with `deposit_returned == false` still owe the creator.

  Fee accruals already collected but not swept stay outside the
  snapshot — they are platform revenue, not user liability.
  """

  @behaviour Vault.Source

  alias PerpWalk.Markets.{Dispute, Market, Position}
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Monero.Facade, as: MoneroFacade

  @impl Vault.Source
  def reserves do
    # `balance` (confirmed unlocked + confirmed locked) rather than
    # `unlocked_balance` alone. The earlier choice of unlocked was
    # over-cautious — it produced false-positive deficit alerts on
    # two routine flows:
    #
    # 1. Outgoing payouts. Every federation payout creates a change
    #    output locked for ~10 confirmations. `unlocked_balance`
    #    drops by the full input value at broadcast; `outstanding`
    #    only drops by `payout_amount`. The gap (= change) showed
    #    as a deficit until the change confirmed.
    # 2. Incoming deposits. `Monero.Poller` transitions a position
    #    to `:open` on first confirmation, so the deposit enters
    #    `outstanding` immediately. The deposit output itself stays
    #    in `locked_balance` for 9 more blocks; `unlocked_balance`
    #    lagged outstanding for the entire ~10-confirmation window.
    #
    # Both alerts cleared naturally, but together they fired on
    # essentially every payout and every deposit — operator alerts
    # would have drowned in noise. `balance` keeps held and
    # outstanding in lockstep through both lifecycles.
    #
    # Residual risk: mempool-only incoming deposits may appear in
    # `balance` (RPC version dependent) without matching outstanding,
    # briefly inflating held. Trade-off: bounded false-surplus from
    # unconfirmed deposit volume, vs constant false-deficit on every
    # payout. The former is small and short-lived.
    case MoneroFacade.balance() do
      {:ok, %{balance: total}} -> %{total_held: total}
      {:error, _} -> %{total_held: 0}
    end
  rescue
    _ -> %{total_held: 0}
  end

  @impl Vault.Source
  def liabilities do
    positions = MarketsFacade.list_all_positions()
    markets = MarketsFacade.list_markets()
    markets_by_id = Map.new(markets, &{&1.id, &1})
    positions_by_market = Enum.group_by(positions, & &1.market_id)
    disputes = MarketsFacade.list_disputes()

    {position_issued, position_redeemed} = compute_face_values(positions, markets_by_id)
    position_outstanding = compute_market_outstanding(markets, positions_by_market)

    dispute_outstanding = compute_dispute_outstanding(disputes)
    creator_outstanding = compute_creator_outstanding(markets)

    %{
      issued: position_issued,
      redeemed: position_redeemed,
      outstanding: position_outstanding + dispute_outstanding + creator_outstanding
    }

    # Deliberately NO rescue clause. Any exception raised inside
    # liability computation (ETS missing mid-restart, MarketsFacade
    # crash, poisoned replicated entry) propagates up to
    # `Vault.Snapshot.capture/1` which surfaces it inside the
    # `Vault.Generator.run_proof_cycle` rescue — the whole proof
    # cycle aborts WITHOUT publishing. The previous rescue-to-zero
    # published fully-attested `outstanding: 0` proofs (ratio
    # `held / 0 = :infinity` → detector `:healthy`) on any
    # transient error, which is the canonical "hide insolvency"
    # failure mode this fixes.
  end

  @impl Vault.Source
  def asset_ids do
    [:active, :expired, :resolving]
    |> Enum.flat_map(&MarketsFacade.list_markets_by_status/1)
    |> Enum.map(& &1.id)
  rescue
    _ -> []
  end

  @impl Vault.Source
  def metadata do
    %{
      epoch_id: 0,
      market_count: safe_call(fn -> length(MarketsFacade.list_markets()) end, 0),
      position_count: safe_call(fn -> length(MarketsFacade.list_all_positions()) end, 0),
      chain_height: safe_call(&chain_height/0, nil)
    }
  end

  # Best-effort Monero top-block height for this guardian. Surfaced as
  # snapshot metadata so peer verification can refuse to attest if a
  # follower's chain view lags the leader's — `total_held` is a
  # chain-state read, and a peer at a lower height cannot honestly
  # confirm the leader's reported balance.
  defp chain_height do
    case MoneroFacade.block_height() do
      {:ok, h} when is_integer(h) -> h
      _ -> nil
    end
  end

  # --- Internal ---

  # `issued` (cumulative face value of every position ever created)
  # and `redeemed` (amounts already paid out via :paid_out) are
  # straight sums — they don't care about market grouping. Pulled
  # out from outstanding because outstanding now needs the per-market
  # max-side grouping that doesn't compose with a simple Enum.reduce.
  defp compute_face_values(positions, markets_by_id) do
    Enum.reduce(positions, {0, 0}, fn position, {issued_acc, redeemed_acc} ->
      case Map.get(markets_by_id, position.market_id) do
        nil ->
          {issued_acc, redeemed_acc}

        market ->
          face_value = position.contracts * market.unit_size
          redeemed = redeemed_for(position, market.unit_size)
          {issued_acc + face_value, redeemed_acc + redeemed}
      end
    end)
  end

  # Per-market outstanding obligation. Iterate over **every market**
  # (not just markets that have positions) — an active market with a
  # seeded pool but no trades yet still owes its creator the full
  # pool residual at settlement, which is part of the worst-case
  # payout. Earlier code grouped by positions, which silently skipped
  # markets with zero positions and undercounted by exactly the
  # initial creator deposit on those.
  defp compute_market_outstanding(markets, positions_by_market) do
    Enum.reduce(markets, 0, fn market, acc ->
      positions = Map.get(positions_by_market, market.id, [])
      acc + market_outstanding(positions, market)
    end)
  end

  defp market_outstanding(positions, market) do
    {open_yes, open_no, settled_winner, refunded} =
      Enum.reduce(positions, {0, 0, 0, 0}, fn p, {oy, on, sw, r} ->
        case {p.status, p.side} do
          {:open, :yes} -> {oy + p.contracts * market.unit_size, on, sw, r}
          {:open, :no} -> {oy, on + p.contracts * market.unit_size, sw, r}
          {:settled_winner, _} -> {oy, on, sw + p.contracts * market.unit_size, r}
          {:refunded, _} -> {oy, on, sw, r + p.amount_paid}
          _ -> {oy, on, sw, r}
        end
      end)

    worst_case_open_payout(open_yes, open_no, market) + settled_winner + refunded
  end

  # For markets with uncertain outcome (`:active`, `:expired`,
  # `:resolving`), the worst-case payout under either resolution
  # equals the winning-side trader total PLUS the creator's residual
  # pool on that side. Under symmetric-seed + AMM-invariant conditions
  # the two sides are equal; the `max` is a safety belt against
  # rounding drift.
  #
  # For terminal / pre-trading states the pool residual is either
  # already counted by `creator_outstanding_for/1` (settled, voided)
  # or doesn't apply (rejected, awaiting_deposit, pending), so the
  # bare trader-side `max` is the correct contribution.
  defp worst_case_open_payout(open_yes, open_no, %Market{status: status} = market)
       when status in [:active, :expired, :resolving] do
    pool_yes_pic = MarketsFacade.subunits_to_piconeros(market.pool.yes, market.unit_size)
    pool_no_pic = MarketsFacade.subunits_to_piconeros(market.pool.no, market.unit_size)
    max(open_yes + pool_yes_pic, open_no + pool_no_pic)
  end

  defp worst_case_open_payout(open_yes, open_no, _market), do: max(open_yes, open_no)

  # Redeemed = amounts already paid out. For paid_out positions, this
  # is the original payout (winner: contracts*unit_size, refund:
  # amount_paid). Other terminal states didn't pay anything.
  defp redeemed_for(%Position{status: :paid_out, contracts: c}, unit_size),
    do: c * unit_size

  defp redeemed_for(%Position{}, _unit_size), do: 0

  # `:resolved_for` and `:resolved_against` disputes have had their
  # outcome decided but not yet paid — the refund Payout is still in
  # flight or queued. `:refunded_*` states have already been paid out
  # by the federation and Dispute.refund_amount_piconeros/1 returns 0.
  defp compute_dispute_outstanding(disputes) do
    Enum.reduce(disputes, 0, fn dispute, acc ->
      case dispute.status do
        s when s in [:resolved_for, :resolved_against] ->
          acc + Dispute.refund_amount_piconeros(dispute)

        _ ->
          acc
      end
    end)
  end

  # Creator LP capital still in custody:
  #
  # - `:voided` markets owe the full deposit back (no trades resolved,
  #   pool wound down to the seed).
  # - `:settled` markets owe the residual = `pool.<winning_side> ×
  #   unit_size` — what's left in the winning-side reserve after
  #   trader payouts. Stops counting once `creator_lp_paid_out_at`
  #   is stamped by the Signer's post-submit hook.
  # - Other statuses: the deposit IS still in the wallet but it's
  #   either active LP capital (not user liability — covered by the
  #   trader-side position outstanding) or hasn't yet been collected
  #   (`:awaiting_deposit`) / has been burned (`:rejected` →
  #   house revenue, not a liability).
  defp compute_creator_outstanding(markets) do
    Enum.reduce(markets, 0, fn market, acc ->
      acc + creator_outstanding_for(market)
    end)
  end

  defp creator_outstanding_for(%Market{status: :voided, creator_lp_paid_out_at: nil} = market),
    do: market.deposit_amount

  defp creator_outstanding_for(%Market{status: :settled, creator_lp_paid_out_at: nil, outcome: :yes} = market),
    do: MarketsFacade.subunits_to_piconeros(market.pool.yes, market.unit_size)

  defp creator_outstanding_for(%Market{status: :settled, creator_lp_paid_out_at: nil, outcome: :no} = market),
    do: MarketsFacade.subunits_to_piconeros(market.pool.no, market.unit_size)

  defp creator_outstanding_for(%Market{}), do: 0

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end
end
