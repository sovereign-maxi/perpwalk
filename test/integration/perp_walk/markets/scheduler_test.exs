defmodule PerpWalk.Markets.SchedulerIntegrationTest do
  @moduledoc """
  Integration tests for the time-driven Markets scheduler.

  Drives transitions explicitly via `Scheduler.run_now/0`. Test
  config sets `tick_interval_ms` to 1h so the scheduler never fires
  spontaneously — every state change here is the result of a
  synchronous run we triggered.
  """

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers,
    only: [activate!: 1, dispute!: 2, pending_market!: 1]

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.{Market, Scheduler, Store}
  alias PerpWalk.Markets.Services.{Resolver, Trader}

  # Override the default-off dispute window for tests that exercise
  # the scheduler's dispute-window logic; keeps the scheduler's
  # settle-vs-hold decision testable end-to-end.
  setup do
    prior = Application.get_env(:perpwalk, :markets_scheduler, [])
    updated = Keyword.put(prior, :dispute_window_seconds, 86_400)
    Application.put_env(:perpwalk, :markets_scheduler, updated)

    on_exit(fn -> Application.put_env(:perpwalk, :markets_scheduler, prior) end)
    :ok
  end

  describe "pending → active" do
    test "activates a pending market once the pending window has elapsed" do
      market = pending_market!([])

      # The listing-vote window anchors on deposit confirmation, not
      # creation — backdate the confirmation to move past the window.
      backdated = %{market | deposit_confirmed_at: DateTime.add(DateTime.utc_now(), -86_500, :second)}
      :ok = Store.put_market(backdated)

      :ok = Scheduler.run_now()

      {:ok, refreshed} = Store.get_market(market.id)
      assert refreshed.status == :active
    end

    test "leaves a pending market alone while still inside the window" do
      market = pending_market!([])

      :ok = Scheduler.run_now()

      {:ok, refreshed} = Store.get_market(market.id)
      assert refreshed.status == :pending
    end
  end

  describe "active → expired" do
    test "expires an active market once expiry has passed" do
      now = DateTime.utc_now()

      market =
        pending_market!(
          expiry: DateTime.add(now, 60, :second),
          resolution_deadline: DateTime.add(now, 86_400 * 2, :second)
        )

      activated = activate!(market)

      expired_setup = %{activated | expiry: DateTime.add(now, -60, :second)}
      :ok = Store.put_market(expired_setup)

      :ok = Scheduler.run_now()

      {:ok, refreshed} = Store.get_market(market.id)
      assert refreshed.status == :expired
    end

    test "leaves an active market alone while expiry is in the future" do
      market = pending_market!([])
      activated = activate!(market)

      :ok = Scheduler.run_now()

      {:ok, refreshed} = Store.get_market(activated.id)
      assert refreshed.status == :active
    end
  end

  describe "auto-void after resolution deadline" do
    test "voids an expired market once resolution deadline + grace has elapsed" do
      now = DateTime.utc_now()

      market = pending_market!([])
      activated = activate!(market)
      {:ok, expired} = Resolver.expire(activated.id)

      overdue = %{expired | resolution_deadline: DateTime.add(now, -86_500, :second)}
      :ok = Store.put_market(overdue)

      :ok = Scheduler.run_now()

      {:ok, refreshed} = Store.get_market(market.id)
      assert refreshed.status == :voided
      assert refreshed.outcome == :void
    end

    test "publishes MarketVoided with reason: :creator_no_show for an :expired market" do
      now = DateTime.utc_now()
      :ok = EventBus.subscribe(MarketsEvents.MarketVoided)

      market = pending_market!([])
      activated = activate!(market)
      {:ok, expired} = Resolver.expire(activated.id)

      overdue = %{expired | resolution_deadline: DateTime.add(now, -86_500, :second)}
      :ok = Store.put_market(overdue)

      :ok = Scheduler.run_now()

      assert_receive %MarketsEvents.MarketVoided{
                       market_id: mid,
                       reason: :creator_no_show
                     },
                     500

      assert mid == market.id
    end

    test "publishes MarketVoided with reason: :guardian_undecidable for a :resolving market past threshold with unacknowledged disputes" do
      now = DateTime.utc_now()
      :ok = EventBus.subscribe(MarketsEvents.MarketVoided)

      # Contested-market path: market trades, expires, gets resolved,
      # accumulates enough live disputes to block auto-settle. The
      # `:guardian_undecidable` void only fires when the federation
      # never acknowledged + resolution_deadline + grace elapsed.
      market = pending_market!([])
      activated = activate!(market)

      # Live disputes blocking settle require >= moderation threshold
      # (default 5); five traders trade then dispute to satisfy both
      # the must-have-traded precondition and the live count.
      for i <- 1..5 do
        {:ok, _} = Trader.place_position("voter-#{i}", activated.id, :yes, 1)
      end

      {:ok, _expired} = Resolver.expire(activated.id)
      {:ok, resolving} = Resolver.submit_resolution(activated.id, :yes)

      for i <- 1..5, do: _ = dispute!("voter-#{i}", activated.id)

      # The :resolving void clock is anchored on `resolution_submitted_at`,
      # not `resolution_deadline`. dispute_window + grace = 172_800s
      # default; -172_900s puts the market just past the cutoff.
      overdue = %{resolving | resolution_submitted_at: DateTime.add(now, -172_900, :second)}
      :ok = Store.put_market(overdue)

      :ok = Scheduler.run_now()

      assert_receive %MarketsEvents.MarketVoided{
                       market_id: mid,
                       reason: :guardian_undecidable
                     },
                     500

      assert mid == market.id
    end

    test "leaves an expired market alone while still inside grace window" do
      market = pending_market!([])
      activated = activate!(market)
      {:ok, _expired} = Resolver.expire(activated.id)

      :ok = Scheduler.run_now()

      {:ok, refreshed} = Store.get_market(market.id)
      assert refreshed.status == :expired
    end

    test "does NOT auto-void a freshly :resolving market when resolution_deadline + grace is past but submission is fresh" do
      # The :resolving void clock is anchored on resolution_submitted_at,
      # so a market with a past resolution_deadline + grace but a fresh
      # submission must stay in :resolving (settle window hasn't opened
      # yet) rather than voiding prematurely.
      market = pending_market!([])
      activated = activate!(market)
      {:ok, expired} = Resolver.expire(activated.id)

      overdue = %{expired | resolution_deadline: DateTime.add(DateTime.utc_now(), -86_500, :second)}
      :ok = Store.put_market(overdue)

      {:ok, _resolving} = Resolver.submit_resolution(activated.id, :yes)

      :ok = Scheduler.run_now()

      {:ok, refreshed} = Store.get_market(market.id)

      assert refreshed.status == :resolving,
             "expected :resolving (submission is fresh), got #{inspect(refreshed.status)}"
    end
  end

  describe "auto-settle after dispute window" do
    test "settles a :resolving market with no disputes once the dispute window has elapsed" do
      :ok = EventBus.subscribe(MarketsEvents.MarketSettled)

      market = pending_market!([])
      activated = activate!(market)
      {:ok, _expired} = Resolver.expire(activated.id)
      {:ok, resolving} = Resolver.submit_resolution(activated.id, :yes)

      # Backdate the resolution submission past the dispute window so
      # the scheduler treats the market as eligible for auto-settle.
      past = DateTime.add(DateTime.utc_now(), -86_500, :second)
      backdated = %{resolving | resolution_submitted_at: past}
      :ok = Store.put_market(backdated)

      :ok = Scheduler.run_now()

      {:ok, refreshed} = Store.get_market(market.id)
      assert refreshed.status == :settled

      assert_receive %MarketsEvents.MarketSettled{market_id: mid, outcome: :yes}, 500
      assert mid == market.id
    end

    test "leaves a :resolving market alone while still inside the dispute window" do
      market = pending_market!([])
      activated = activate!(market)
      {:ok, _expired} = Resolver.expire(activated.id)
      {:ok, _resolving} = Resolver.submit_resolution(activated.id, :yes)

      :ok = Scheduler.run_now()

      {:ok, refreshed} = Store.get_market(market.id)
      assert refreshed.status == :resolving
    end

    test "auto-settles a :resolving market with sub-threshold live disputes (implicit acknowledge)" do
      # Live disputes below the moderation threshold do not block
      # settle — Resolver.settle/1 implicitly acknowledges them and
      # transitions them to :resolved_for. The tick path must call
      # settle (which knows this) rather than refusing on a strict
      # live_count == 0 check.
      :ok = EventBus.subscribe(MarketsEvents.MarketSettled)

      market = pending_market!([])
      activated = activate!(market)

      # Need a position holder to file the dispute (must-have-traded
      # precondition). One trader, one sub-threshold dispute.
      {:ok, _} = Trader.place_position("voter-1", activated.id, :yes, 1)

      {:ok, _expired} = Resolver.expire(activated.id)
      {:ok, resolving} = Resolver.submit_resolution(activated.id, :yes)

      _ = dispute!("voter-1", activated.id)

      # Backdate submission past the dispute window so the tick is
      # eligible for settle.
      past = DateTime.add(DateTime.utc_now(), -86_500, :second)
      :ok = Store.put_market(%{resolving | resolution_submitted_at: past})

      :ok = Scheduler.run_now()

      {:ok, refreshed} = Store.get_market(market.id)
      assert refreshed.status == :settled
      assert refreshed.outcome == :yes

      assert_receive %MarketsEvents.MarketSettled{market_id: mid, outcome: :yes}, 500
      assert mid == market.id
    end

    test "leaves a :resolving market with no resolution_submitted_at alone (pre-feature compat)" do
      # Old WAL entries that pre-date `resolution_submitted_at` read
      # back as nil. The auto-settle path skips them; they fall
      # through to the existing `void_overdue` path at
      # resolution_deadline + grace.
      market = pending_market!([])
      activated = activate!(market)
      {:ok, _expired} = Resolver.expire(activated.id)
      {:ok, resolving} = Resolver.submit_resolution(activated.id, :yes)

      stamped = %{resolving | resolution_submitted_at: nil}
      :ok = Store.put_market(stamped)

      :ok = Scheduler.run_now()

      {:ok, refreshed} = Store.get_market(market.id)
      assert refreshed.status == :resolving
    end

    test "settles, never voids, an uncontested market even when resolution_deadline + grace also elapsed" do
      # Both clocks (dispute_window and auto_void_grace) tick to past
      # simultaneously. The auto-settle scan runs FIRST in the tick
      # ordering, so the market settles cleanly rather than voiding
      # as :guardian_undecidable.
      :ok = EventBus.subscribe(MarketsEvents.MarketSettled)

      market = pending_market!([])
      activated = activate!(market)
      {:ok, _expired} = Resolver.expire(activated.id)
      {:ok, resolving} = Resolver.submit_resolution(activated.id, :yes)

      past = DateTime.add(DateTime.utc_now(), -86_500, :second)

      both_past = %{
        resolving
        | resolution_submitted_at: past,
          resolution_deadline: past
      }

      :ok = Store.put_market(both_past)

      :ok = Scheduler.run_now()

      {:ok, refreshed} = Store.get_market(market.id)
      assert refreshed.status == :settled

      assert_receive %MarketsEvents.MarketSettled{market_id: mid}, 500
      assert mid == market.id
    end
  end

  describe "fault tolerance" do
    test "scan continues across multiple markets even on per-market issues" do
      now = DateTime.utc_now()

      m1_raw = pending_market!(description: "First")
      m2_raw = pending_market!(description: "Second")

      backdated = fn m -> %{m | deposit_confirmed_at: DateTime.add(now, -86_500, :second)} end

      :ok = Store.put_market(backdated.(m1_raw))
      :ok = Store.put_market(backdated.(m2_raw))

      :ok = Scheduler.run_now()

      assert {:ok, %Market{status: :active}} = Store.get_market(m1_raw.id)
      assert {:ok, %Market{status: :active}} = Store.get_market(m2_raw.id)
    end
  end
end
