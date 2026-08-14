defmodule PerpWalk.Sim.Invariants.Concurrency do
  @moduledoc """
  Verifies concurrent state mutations leave the store in a coherent
  shape — specifically the settle-vs-dispute race guarded by
  `Markets.Store.put_resolution_cas/3`.

  Per-tick checks (always-on):

  1. `:settled` markets do not have any `:live` disputes whose
     `deposit_confirmed_at` is later than the market's
     `resolved_at`. A `:live` dispute cannot post-date the
     settle commit — if it did, the CAS guard failed.
  2. `:settled` markets cannot have any `:awaiting_deposit`
     disputes whose deposit confirmation post-dates the settle.
     Confirmed-before-settle awaiting-deposit records are
     legitimate (the deposit just hasn't landed yet).

  The `Race` scenario actively races settles vs disputes to
  exercise the CAS path. This invariant detects breakage from
  any source.

  ## Indexed reads

  Uses `Store.list_markets_by_status(:settled)` and
  `Store.list_disputes_for_market/1` directly rather than scanning
  the snapshot's full markets / disputes lists. Settled markets
  are typically a small fraction of total markets, and per-market
  dispute lookup is bounded by the index entry count for that
  market — so per-validate cost is O(settled + their disputes)
  not O(total markets + total disputes). The race window between
  the two indexed reads is benign because the settle-dispute
  coherence invariant is monotonic: if it's violated at any
  moment it stays violated, and the next validate call catches it.

  ## Known domain note

  Sub-threshold `:live` disputes that confirmed *before* settle
  remain on `:settled` markets as an under-specified state —
  `Resolver.settle/1` only verifies the threshold isn't crossed
  but doesn't transition surviving live disputes to terminal.
  That's a domain design question, not a CAS race, so this
  invariant doesn't flag it.
  """

  alias PerpWalk.Markets.Store
  alias PerpWalk.Sim.Run

  @spec check(map()) :: :ok | {:violation, map()}
  def check(_snapshot) do
    settled =
      :settled
      |> Store.list_markets_by_status()
      |> Enum.filter(&Run.from_current_run?(&1.created_at))

    violations =
      Enum.flat_map(settled, fn market ->
        market.id
        |> Store.list_disputes_for_market()
        |> Enum.flat_map(&dispute_violation(market, &1))
      end)

    if violations == [] do
      :ok
    else
      {:violation,
       %{
         kind: :settle_dispute_coherence,
         count: length(violations),
         sample: Enum.take(violations, 3)
       }}
    end
  end

  # --- Internal ---

  defp dispute_violation(market, %{status: status} = dispute)
       when status in [:live, :awaiting_deposit] do
    confirmed_after_settle? =
      dispute.deposit_confirmed_at != nil and market.resolved_at != nil and
        DateTime.compare(dispute.deposit_confirmed_at, market.resolved_at) == :gt

    if confirmed_after_settle? do
      [
        %{
          market_id: market.id,
          dispute_account: dispute.account_id,
          kind: :live_dispute_after_settle,
          settled_at: market.resolved_at,
          confirmed_at: dispute.deposit_confirmed_at
        }
      ]
    else
      []
    end
  end

  defp dispute_violation(_market, _dispute), do: []
end
