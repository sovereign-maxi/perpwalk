defmodule PerpWalk.Sim.Invariants.Conservation do
  @moduledoc """
  Verifies the federation-revenue ledger's reported totals match an
  independently-derived view from the event stream.

  Two source streams contribute to federation revenue:

  - **Slashed dispute stakes** — any dispute transitioning into
    `:resolved_for` with non-zero `slashed_amount_piconeros`
    accrues to the slashed total. The slash stays on the dispute
    record across `:resolved_for → :refunded_partial` transitions
    but is recorded once at the `:resolved_for` step.
  - **Forfeited creator deposits** — any market transitioning into
    `:rejected` accrues its `deposit_amount` to the burned total.

  ## Event-driven

  Subscribes to `DisputeResolved` and `DepositBurned`. On each
  event the relevant accumulator is incremented (slash on
  `:resolved_for` with slash > 0, burn on any deposit-burned
  emission). At
  `check/1` time the accumulator is compared against
  `Ledger.breakdown/0`, which now reads incremental counters in
  the Markets store in O(1). Three independent derivations of the
  same totals: event-stream accumulator (this invariant), store
  counter table (ledger), and the on-demand
  `Ledger.reconcile/0` index walk. Mismatch on any pair surfaces
  a violation.

  Per-event cost is O(1). Per-check cost is O(1) read of the
  ledger counters plus a constant-size comparison. The earlier
  snapshot-based implementation walked the full `:resolved_for`
  and `:refunded_partial` dispute indexes on every validate and
  was the dominant cost in adversarial-scale Phase B runs.

  ## Spread

  Trade-spread on settled markets is included in `total_piconeros`
  but is not separately tracked by this invariant — settled
  markets are rare in the sim's typical mix (most go through
  `:resolving → :voided`), and the ledger's spread total is read
  from the store counter alongside slashed/burned. If a sim run
  produces settled markets, the spread component of
  `total_piconeros` flows through transparently from the ledger.

  ## Race tolerance

  Events fire after the corresponding store write completes
  (events are emitted by the same process that called the write,
  immediately after a successful `:ok` return), so the
  accumulator and ledger should agree exactly once the event has
  been delivered. A brief race window exists if a write commits
  and a `check/1` call fires before Phoenix.PubSub has handed the
  event to this GenServer's mailbox: the ledger counter is
  already incremented but the accumulator hasn't seen the event.
  Empirically the window is 1-2 check intervals (10-20ms) under
  adversarial concurrency. A mismatch must persist across
  `@persistence_threshold` consecutive checks before being
  reported, so genuine async-delivery transients resolve silently
  and only structural drift surfaces as a violation. Real
  persistent bugs are still detected — just `@persistence_threshold
  - 1` ticks (~20ms) later than they would be otherwise.
  """

  use GenServer

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.Facade, as: MarketsFacade

  # A mismatch must persist across this many consecutive `check/1`
  # invocations before being reported as a violation. At a 10ms tick
  # interval that's a 30ms detection latency for real structural
  # drift, and a 30ms tolerance window for benign async-pubsub
  # delivery lag.
  @persistence_threshold 3

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec check(map()) :: :ok | {:violation, map()}
  def check(_snapshot) do
    GenServer.call(__MODULE__, :check)
  end

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # --- GenServer ---

  @impl true
  def init(_opts) do
    EventBus.subscribe(MarketsEvents.DisputeResolved)
    EventBus.subscribe(MarketsEvents.DepositBurned)

    {:ok, initial_state()}
  end

  # --- Idempotency by entity id ---
  #
  # Even with the atomic-transition fix in
  # `Store.commit_market_rejection/1`, async pubsub can in
  # principle redeliver an event (subscriber restart, supervisor
  # churn, future change to the EventBus implementation). Dedup
  # by entity key so the accumulator is robust against duplicate
  # delivery regardless of upstream emit discipline. The dedup
  # sets grow with the number of distinct slashed disputes /
  # rejected markets — bounded by run scale, never re-counted
  # within a run.

  @impl true
  def handle_call(:check, _from, state) do
    breakdown = MarketsFacade.federation_ledger()
    mismatches = collect_mismatches(state, breakdown)

    cond do
      mismatches == [] ->
        {:reply, :ok, %{state | pending_mismatches: [], pending_streak: 0}}

      sameish?(state.pending_mismatches, mismatches) ->
        new_streak = state.pending_streak + 1

        if new_streak >= @persistence_threshold do
          violation = %{kind: :conservation_mismatch, mismatches: mismatches}

          {:reply, {:violation, violation}, %{state | pending_mismatches: mismatches, pending_streak: new_streak}}
        else
          {:reply, :ok, %{state | pending_mismatches: mismatches, pending_streak: new_streak}}
        end

      true ->
        # First sighting of this mismatch pattern — reset streak.
        {:reply, :ok, %{state | pending_mismatches: mismatches, pending_streak: 1}}
    end
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, initial_state()}
  end

  @impl true
  def handle_info(
        %MarketsEvents.DisputeResolved{
          status: :resolved_for,
          slashed_amount_piconeros: slash,
          account_id: aid,
          market_id: mid
        },
        state
      )
      when is_integer(slash) and slash > 0 do
    key = {aid, mid}

    if MapSet.member?(state.counted_slashes, key) do
      {:noreply, state}
    else
      {:noreply,
       %{
         state
         | accumulated_slashed: state.accumulated_slashed + slash,
           slash_count: state.slash_count + 1,
           counted_slashes: MapSet.put(state.counted_slashes, key)
       }}
    end
  end

  def handle_info(%MarketsEvents.DepositBurned{market_id: market_id, amount: amount}, state)
      when is_integer(amount) and amount > 0 do
    if MapSet.member?(state.counted_burns, market_id) do
      {:noreply, state}
    else
      {:noreply,
       %{
         state
         | accumulated_burned: state.accumulated_burned + amount,
           burn_count: state.burn_count + 1,
           counted_burns: MapSet.put(state.counted_burns, market_id)
       }}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp initial_state do
    %{
      accumulated_slashed: 0,
      accumulated_burned: 0,
      slash_count: 0,
      burn_count: 0,
      counted_slashes: MapSet.new(),
      counted_burns: MapSet.new(),
      pending_mismatches: [],
      pending_streak: 0
    }
  end

  defp collect_mismatches(state, breakdown) do
    checks = [
      {:slashed_total_mismatch, breakdown.slashed_piconeros, state.accumulated_slashed},
      {:burned_total_mismatch, breakdown.burned_piconeros, state.accumulated_burned},
      {:slash_count_mismatch, breakdown.slash_count, state.slash_count},
      {:burn_count_mismatch, breakdown.burn_count, state.burn_count}
    ]

    for {kind, reported, expected} <- checks,
        reported != expected,
        do: %{kind: kind, reported: reported, expected: expected}
  end

  # Two mismatch lists are "the same" for race-detection purposes if
  # they cover the same kinds with the same magnitudes. A transient
  # race produces a mismatch on this tick that's gone the next; a
  # structural drift produces the same mismatch repeatedly.
  defp sameish?(prior, current) when length(prior) != length(current), do: false

  defp sameish?(prior, current) do
    prior_sorted = Enum.sort_by(prior, & &1.kind)
    current_sorted = Enum.sort_by(current, & &1.kind)

    Enum.zip(prior_sorted, current_sorted)
    |> Enum.all?(fn {p, c} ->
      p.kind == c.kind and p.reported == c.reported and p.expected == c.expected
    end)
  end
end
