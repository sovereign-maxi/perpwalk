defmodule PerpWalk.Scenarios.MarketsLifecycleTest do
  @moduledoc """
  End-to-end coverage for the market state machine across the
  paths users actually traverse from creation through terminal state.

  Each scenario drives a market from `:pending` (or already-active)
  through one terminal outcome by triggering `Scheduler.run_now/0`
  after manipulating timestamps to simulate time passing. The
  scheduler delegates all eligibility logic to
  `PerpWalk.Markets.Services.Resolver.tick/2`, so these scenarios
  also serve as the load-bearing coverage for that single-source-of-
  truth design — if scheduler ever drifts from resolver, the
  scenarios catch it.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import PerpWalk.TestHelpers.CleanState, only: [clean_state: 1]

  import PerpWalk.TestHelpers.MarketsHelpers,
    only: [activate!: 1, dispute!: 2, pending_market!: 1]

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.{Facade, Scheduler, Store}
  alias PerpWalk.Markets.Services.{Resolver, Trader}

  setup :clean_state

  # This suite exercises the scheduler's dispute-window logic
  # explicitly — override the test-config `dispute_window_seconds: 0`
  # (which disables the settle-time gate for unit/integration tests
  # that immediately settle) back to the production default so the
  # backdating patterns in each scenario land on the intended side
  # of the window.
  setup do
    prior = Application.get_env(:perpwalk, :markets_scheduler, [])
    updated = Keyword.put(prior, :dispute_window_seconds, 86_400)
    Application.put_env(:perpwalk, :markets_scheduler, updated)

    on_exit(fn -> Application.put_env(:perpwalk, :markets_scheduler, prior) end)
    :ok
  end

  # --- Happy path ---------------------------------------------------

  describe "settle — uncontested" do
    test "creator submits YES, dispute window elapses with no disputes, market settles" do
      :ok = EventBus.subscribe(MarketsEvents.MarketSettled)

      market = pending_market!([])
      activated = activate!(market)
      {:ok, _} = Trader.place_position("trader-1", activated.id, :yes, 10)

      {:ok, _expired} = Resolver.expire(activated.id)
      {:ok, resolving} = Resolver.submit_resolution(activated.id, :yes)

      # Inside the dispute window — tick must not settle yet.
      :ok = Scheduler.run_now()
      {:ok, mid_window} = Store.get_market(activated.id)
      assert mid_window.status == :resolving

      # Backdate submission past the dispute window. Next tick settles.
      past = DateTime.add(DateTime.utc_now(), -86_500, :second)
      :ok = Store.put_market(%{resolving | resolution_submitted_at: past})

      :ok = Scheduler.run_now()

      {:ok, settled} = Store.get_market(activated.id)
      assert settled.status == :settled
      assert settled.outcome == :yes
      assert settled.resolved_at

      assert_receive %MarketsEvents.MarketSettled{
                       market_id: mid,
                       outcome: :yes
                     },
                     500

      assert mid == activated.id

      # Position transitions to :settled_winner.
      [position] = Facade.list_positions_for_market(activated.id)
      assert position.status == :settled_winner
    end
  end

  # --- Bug regressions ----------------------------------------------

  describe "settle — submission inside expired grace window" do
    test "creator submits after deadline but inside grace, market settles (does NOT auto-void)" do
      # The previously-buggy void clock was anchored on
      # `resolution_deadline + grace`. When a creator submitted late
      # but inside the grace window, that cutoff would still fire
      # before `submitted_at + dispute_window` opened settle, and the
      # market voided as :guardian_undecidable. Scenario reproduces
      # the original incident; passes only when the void clock is
      # correctly anchored on `submitted_at + dispute_window + grace`.
      :ok = EventBus.subscribe(MarketsEvents.MarketSettled)
      :ok = EventBus.subscribe(MarketsEvents.MarketVoided)

      market = pending_market!([])
      activated = activate!(market)
      {:ok, _} = Trader.place_position("trader-1", activated.id, :yes, 10)

      {:ok, expired} = Resolver.expire(activated.id)

      # Move resolution_deadline well into the past (past grace),
      # then have the creator submit YES. Submission is fresh.
      past_deadline = DateTime.add(DateTime.utc_now(), -86_500, :second)
      :ok = Store.put_market(%{expired | resolution_deadline: past_deadline})
      {:ok, resolving} = Resolver.submit_resolution(activated.id, :yes)

      :ok = Scheduler.run_now()

      {:ok, after_first} = Store.get_market(activated.id)

      assert after_first.status == :resolving,
             "expected :resolving (fresh submission), got #{inspect(after_first.status)} — " <>
               "void clock regressed to deadline-anchored"

      refute_receive %MarketsEvents.MarketVoided{}, 100

      # Now backdate submission past the dispute window and tick — settle.
      past_submit = DateTime.add(DateTime.utc_now(), -86_500, :second)
      :ok = Store.put_market(%{resolving | resolution_submitted_at: past_submit})

      :ok = Scheduler.run_now()

      {:ok, settled} = Store.get_market(activated.id)
      assert settled.status == :settled
      assert settled.outcome == :yes

      assert_receive %MarketsEvents.MarketSettled{outcome: :yes}, 500
    end
  end

  describe "settle — sub-threshold live disputes (implicit acknowledge)" do
    test "single live dispute below moderation threshold settles via implicit acknowledge" do
      # Previously the scheduler refused settle if `live_dispute_count`
      # was anything but zero. The resolver's `Resolver.settle/1`
      # tolerates sub-threshold disputes via implicit acknowledge
      # (each disputer's row transitions to :resolved_for, refund
      # claim is unblocked). Scenario confirms a single dispute does
      # not strand the market.
      :ok = EventBus.subscribe(MarketsEvents.MarketSettled)

      market = pending_market!([])
      activated = activate!(market)
      {:ok, _} = Trader.place_position("disputer", activated.id, :yes, 10)

      {:ok, _expired} = Resolver.expire(activated.id)
      {:ok, resolving} = Resolver.submit_resolution(activated.id, :yes)

      _ = dispute!("disputer", activated.id)

      past = DateTime.add(DateTime.utc_now(), -86_500, :second)
      :ok = Store.put_market(%{resolving | resolution_submitted_at: past})

      :ok = Scheduler.run_now()

      {:ok, settled} = Store.get_market(activated.id)
      assert settled.status == :settled
      assert settled.outcome == :yes

      assert_receive %MarketsEvents.MarketSettled{outcome: :yes}, 500

      # Sub-threshold dispute auto-transitions to :resolved_for.
      [dispute] = Facade.list_disputes_for_market(activated.id)
      assert dispute.status == :resolved_for
    end
  end

  # --- Void paths ---------------------------------------------------

  describe "void — guardian_undecidable" do
    test "over-threshold disputes with no federation action void the market" do
      :ok = EventBus.subscribe(MarketsEvents.MarketVoided)

      market = pending_market!([])
      activated = activate!(market)

      # 5 traders to clear the moderation threshold (default floor: 5).
      for i <- 1..5 do
        {:ok, _} = Trader.place_position("voter-#{i}", activated.id, :yes, 1)
      end

      {:ok, _expired} = Resolver.expire(activated.id)
      {:ok, resolving} = Resolver.submit_resolution(activated.id, :yes)

      for i <- 1..5, do: _ = dispute!("voter-#{i}", activated.id)

      # Federation never acknowledges. Backdate past submit_window +
      # grace so the void clock fires.
      past = DateTime.add(DateTime.utc_now(), -172_900, :second)
      :ok = Store.put_market(%{resolving | resolution_submitted_at: past})

      :ok = Scheduler.run_now()

      {:ok, voided} = Store.get_market(activated.id)
      assert voided.status == :voided
      assert voided.outcome == :void

      assert_receive %MarketsEvents.MarketVoided{reason: :guardian_undecidable}, 500

      # All disputers refunded fully (no slash) per the void-from-
      # resolving rule.
      disputes = Facade.list_disputes_for_market(activated.id)
      assert length(disputes) == 5
      assert Enum.all?(disputes, &(&1.status == :resolved_against))
      assert Enum.all?(disputes, &(&1.slashed_amount_piconeros == 0))
    end
  end

  describe "void — creator_no_show" do
    test "creator never submits, market voids after resolution_deadline + grace elapses" do
      :ok = EventBus.subscribe(MarketsEvents.MarketVoided)

      market = pending_market!([])
      activated = activate!(market)
      {:ok, _} = Trader.place_position("trader-1", activated.id, :yes, 10)

      {:ok, expired} = Resolver.expire(activated.id)

      # Inside the grace window — tick must not void.
      :ok = Scheduler.run_now()
      {:ok, inside_grace} = Store.get_market(activated.id)
      assert inside_grace.status == :expired

      # Backdate deadline past grace. Next tick voids.
      past_deadline = DateTime.add(DateTime.utc_now(), -86_500, :second)
      :ok = Store.put_market(%{expired | resolution_deadline: past_deadline})

      :ok = Scheduler.run_now()

      {:ok, voided} = Store.get_market(activated.id)
      assert voided.status == :voided
      assert voided.outcome == :void

      assert_receive %MarketsEvents.MarketVoided{reason: :creator_no_show}, 500

      # Position transitions to :refunded.
      [position] = Facade.list_positions_for_market(activated.id)
      assert position.status == :refunded
    end
  end

  # --- Federation override -----------------------------------------

  describe "settle — federation reverses creator's resolution" do
    test "creator submits YES, federation reverses to NO, market settles as NO" do
      :ok = EventBus.subscribe(MarketsEvents.MarketSettled)

      market = pending_market!([])
      activated = activate!(market)

      for i <- 1..5 do
        {:ok, _} = Trader.place_position("voter-#{i}", activated.id, :yes, 1)
      end

      {:ok, _expired} = Resolver.expire(activated.id)
      {:ok, _resolving} = Resolver.submit_resolution(activated.id, :yes)

      for i <- 1..5, do: _ = dispute!("voter-#{i}", activated.id)

      # Federation reviews and reverses to NO (disputers were right).
      {:ok, reversed} = Resolver.reverse_resolution(activated.id, :no)
      assert reversed.outcome == :no
      assert reversed.status == :resolving

      # Backdate submission past the dispute window and tick.
      # `reverse_resolution/2` does not update `resolution_submitted_at`
      # by design — the dispute window was already opened by the
      # original submit; reversal just changes the outcome that will
      # settle when the window closes.
      past = DateTime.add(DateTime.utc_now(), -86_500, :second)
      :ok = Store.put_market(%{reversed | resolution_submitted_at: past})

      :ok = Scheduler.run_now()

      {:ok, settled} = Store.get_market(activated.id)
      assert settled.status == :settled
      assert settled.outcome == :no

      assert_receive %MarketsEvents.MarketSettled{outcome: :no}, 500

      # Positions bought YES; market resolved NO → settled_loser.
      positions = Facade.list_positions_for_market(activated.id)
      assert length(positions) == 5
      assert Enum.all?(positions, &(&1.status == :settled_loser))
    end
  end
end
