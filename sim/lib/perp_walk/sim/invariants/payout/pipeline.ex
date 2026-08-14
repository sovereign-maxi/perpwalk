defmodule PerpWalk.Sim.Invariants.Payout.Pipeline do
  @moduledoc """
  Verifies every enqueued Payout eventually reaches a terminal
  status (`:paid_out` or `:failed`). Payouts stuck in
  `:pending / :rules_passed / :awaiting_operator / :signing /
  :submitted` for more than `@stuck_threshold_checks` validator
  ticks are surfaced as a violation — they indicate the Signer
  or downstream pipeline has silently stalled.

  ## Event-driven, poll-verified

  - Subscribes to `PayoutRequested` (records the payout id +
    the check-count at which we first saw it).
  - Subscribes to `PayoutFailed` (drains from tracking; failure
    is terminal).
  - On every `check/1`, walks the still-tracked ids, reads the
    live status from `Federation.Facade.get_request/1`, drops
    terminals, and flags stale in-flight rows.

  Tracks in-flight ids only, so per-check cost is O(in-flight)
  rather than O(all-payouts). Under normal load in-flight is
  small — the pipeline drains within a few Signer ticks.

  ## Threshold

  Default: 30 checks. At the harness's typical
  `--validate-every 50` ticks × `--tick-ms 10` = 500 ms per
  check, that's 15 seconds of sim-clock drift before a stall
  fires. Tune down for tight scenarios (e.g. crash-recovery)
  where a longer window would mask a genuine bug.

  ## What this DOESN'T cover

  A payout that reaches `:paid_out` on a *wrong* Position
  (double-payout, incorrect market/account) is Idempotency's
  domain and Ownership's domain. This invariant is only about
  liveness — every request eventually terminates one way or
  the other.
  """

  use GenServer

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Federation.Facade, as: FederationFacade

  @default_stuck_threshold_checks 30

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Validator-contract check/1. Snapshot is ignored."
  @spec check(map()) :: :ok | {:violation, map()}
  def check(_snapshot) do
    case GenServer.call(__MODULE__, :snapshot) do
      [] ->
        :ok

      violations ->
        {:violation,
         %{
           kind: :payout_stuck,
           count: length(violations),
           sample: Enum.take(violations, 5)
         }}
    end
  end

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # --- GenServer ---

  @impl true
  def init(opts) do
    EventBus.subscribe(FederationEvents.PayoutRequested)
    EventBus.subscribe(FederationEvents.PayoutFailed)

    threshold = Keyword.get(opts, :stuck_threshold_checks, @default_stuck_threshold_checks)

    {:ok,
     %{
       check_counter: 0,
       tracked: %{},
       reported: MapSet.new(),
       stuck_threshold_checks: threshold
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = %{state | check_counter: state.check_counter + 1}
    {stale, still_tracked} = walk_tracked(state)

    new_state = %{
      state
      | tracked: still_tracked,
        reported: MapSet.union(state.reported, MapSet.new(Enum.map(stale, & &1.request_id)))
    }

    {:reply, stale, new_state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok,
     %{state | check_counter: 0, tracked: %{}, reported: MapSet.new()}}
  end

  @impl true
  def handle_info(
        %FederationEvents.PayoutRequested{request_id: rid, kind: kind},
        state
      ) do
    tracked =
      Map.put_new(state.tracked, rid, %{seen_at_check: state.check_counter, kind: kind})

    {:noreply, %{state | tracked: tracked}}
  end

  def handle_info(%FederationEvents.PayoutFailed{request_id: rid}, state) do
    {:noreply, %{state | tracked: Map.delete(state.tracked, rid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  # For every tracked payout: look up its live status. Terminal →
  # drop. In-flight past threshold → surface as a stale violation
  # (and drop, so we don't re-report every check). In-flight but
  # within threshold → keep tracking.
  defp walk_tracked(state) do
    Enum.reduce(state.tracked, {[], %{}}, fn {rid, meta}, {stale_acc, kept} ->
      case FederationFacade.get_request(rid) do
        {:ok, payout} ->
          cond do
            payout.status in [:paid_out, :failed] ->
              {stale_acc, kept}

            state.check_counter - meta.seen_at_check > state.stuck_threshold_checks ->
              violation = %{
                request_id: rid,
                kind: meta.kind,
                status: payout.status,
                age_checks: state.check_counter - meta.seen_at_check
              }

              {[violation | stale_acc], kept}

            true ->
              {stale_acc, Map.put(kept, rid, meta)}
          end

        {:error, :not_found} ->
          # Payout row vanished — either replaced by a fresh row
          # (rare), or store data loss. Not our violation to raise,
          # Lifecycle handles orphan-parent checks.
          {stale_acc, kept}
      end
    end)
  end
end
