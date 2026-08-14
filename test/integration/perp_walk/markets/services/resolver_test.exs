defmodule PerpWalk.Markets.Services.ResolverIntegrationTest do
  @moduledoc "Integration tests for PerpWalk.Markets.Services.Resolver."

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers, only: [activate!: 1, pending_market!: 1]

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.{AMM, Store}
  alias PerpWalk.Markets.Services.{Disputer, Resolver, Trader}

  defp create_pending(opts \\ []) do
    market = pending_market!(opts)
    market
  end

  defp create_active(opts \\ []) do
    activate!(create_pending(opts))
  end

  defp create_expired(opts \\ []) do
    market = create_active(opts)
    {:ok, expired} = Resolver.expire(market.id)
    expired
  end

  defp create_resolving(opts, outcome) do
    expired = create_expired(opts)
    {:ok, resolving} = Resolver.submit_resolution(expired.id, outcome)
    resolving
  end

  describe "activate/1" do
    test "transitions :pending → :active and publishes MarketActivated" do
      :ok = EventBus.subscribe(MarketsEvents.MarketActivated)
      pending = create_pending()

      assert {:ok, active} = Resolver.activate(pending.id)
      assert active.status == :active

      assert_receive %MarketsEvents.MarketActivated{market_id: id}, 1_000
      assert id == pending.id

      EventBus.unsubscribe(MarketsEvents.MarketActivated)
    end

    test "errors when market is already :active (not :pending)" do
      market = create_active()

      assert {:error, :invalid_transition} = Resolver.activate(market.id)
    end

    test "errors when market does not exist" do
      assert {:error, :market_not_found} = Resolver.activate("missing")
    end
  end

  describe "expire/1" do
    test "transitions :active → :expired and publishes MarketExpired" do
      :ok = EventBus.subscribe(MarketsEvents.MarketExpired)
      market = create_active()

      assert {:ok, expired} = Resolver.expire(market.id)
      assert expired.status == :expired

      assert_receive %MarketsEvents.MarketExpired{market_id: id}, 1_000
      assert id == market.id

      EventBus.unsubscribe(MarketsEvents.MarketExpired)
    end

    test "errors from :pending" do
      pending = create_pending()
      assert {:error, :invalid_transition} = Resolver.expire(pending.id)
    end
  end

  describe "submit_resolution/2" do
    test "transitions :expired → :resolving with outcome and publishes event" do
      :ok = EventBus.subscribe(MarketsEvents.ResolutionSubmitted)
      market = create_expired()

      assert {:ok, resolving} = Resolver.submit_resolution(market.id, :yes)
      assert resolving.status == :resolving
      assert resolving.outcome == :yes

      assert_receive %MarketsEvents.ResolutionSubmitted{
                       market_id: id,
                       outcome: :yes
                     },
                     1_000

      assert id == market.id

      EventBus.unsubscribe(MarketsEvents.ResolutionSubmitted)
    end

    test "accepts every legal outcome" do
      for outcome <- [:yes, :no, :void] do
        market = create_expired()
        assert {:ok, resolving} = Resolver.submit_resolution(market.id, outcome)
        assert resolving.outcome == outcome
      end
    end

    test "errors from :active" do
      market = create_active()
      assert {:error, :invalid_transition} = Resolver.submit_resolution(market.id, :yes)
    end
  end

  describe "submit_resolution_by_creator/3 — auth-checked path" do
    test "creator can submit a resolution on their own market" do
      market = create_expired()

      assert {:ok, resolving} =
               Resolver.submit_resolution_by_creator(
                 market.creator_account_id,
                 market.id,
                 :yes
               )

      assert resolving.status == :resolving
      assert resolving.outcome == :yes
    end

    test "non-creator is rejected with :not_creator (does not transition)" do
      market = create_expired()

      assert {:error, :not_creator} =
               Resolver.submit_resolution_by_creator("someone-else", market.id, :no)

      # Market remains :expired — no state mutation on auth failure.
      {:ok, untouched} = Store.get_market(market.id)
      assert untouched.status == :expired
      assert untouched.outcome == nil
    end

    test "unknown market id returns :market_not_found" do
      assert {:error, :market_not_found} =
               Resolver.submit_resolution_by_creator("acct", "no-such-market", :yes)
    end

    test "operator override path bypasses creator check" do
      # Creator-less call (Resolver.submit_resolution/2) is the
      # operator-override path; should still work.
      market = create_expired()
      assert {:ok, resolving} = Resolver.submit_resolution(market.id, :no)
      assert resolving.outcome == :no
    end

    test "creator can NOT submit :void — that's operator-only" do
      market = create_expired()

      assert {:error, :invalid_outcome_for_creator} =
               Resolver.submit_resolution_by_creator(
                 market.creator_account_id,
                 market.id,
                 :void
               )

      # No state mutation — market stays :expired.
      {:ok, untouched} = Store.get_market(market.id)
      assert untouched.status == :expired
      assert untouched.outcome == nil
    end

    test "operator override path can still submit :void" do
      market = create_expired()
      assert {:ok, resolving} = Resolver.submit_resolution(market.id, :void)
      assert resolving.outcome == :void
    end
  end

  describe "reverse_resolution/2" do
    test "swaps outcome while staying in :resolving and publishes event" do
      :ok = EventBus.subscribe(MarketsEvents.ResolutionReversed)
      market = create_resolving([], :yes)

      assert {:ok, reversed} = Resolver.reverse_resolution(market.id, :no)
      assert reversed.status == :resolving
      assert reversed.outcome == :no

      assert_receive %MarketsEvents.ResolutionReversed{
                       market_id: id,
                       previous_outcome: :yes,
                       new_outcome: :no
                     },
                     1_000

      assert id == market.id

      EventBus.unsubscribe(MarketsEvents.ResolutionReversed)
    end

    test "errors from :expired" do
      market = create_expired()
      assert {:error, :invalid_transition} = Resolver.reverse_resolution(market.id, :no)
    end
  end

  describe "settle/1 — happy paths" do
    test "settles winners and losers atomically; market moves to :settled" do
      :ok = EventBus.subscribe(MarketsEvents.MarketSettled)

      market = create_active(pool: AMM.new(1_000, 1_000))
      {:ok, winner_pos} = Trader.place_position("alice", market.id, :yes, 50)
      {:ok, loser_pos} = Trader.place_position("bob", market.id, :no, 50)

      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.submit_resolution(market.id, :yes)

      assert {:ok, settled} = Resolver.settle(market.id)
      assert settled.status == :settled
      assert settled.outcome == :yes
      assert %DateTime{} = settled.resolved_at

      {:ok, w} = Store.get_position(winner_pos.id)
      assert w.status == :settled_winner
      assert %DateTime{} = w.settled_at

      {:ok, l} = Store.get_position(loser_pos.id)
      assert l.status == :settled_loser

      assert_receive %MarketsEvents.MarketSettled{
                       market_id: id,
                       outcome: :yes
                     },
                     1_000

      assert id == market.id

      EventBus.unsubscribe(MarketsEvents.MarketSettled)
    end

    test "settles a market with zero positions cleanly" do
      market = create_resolving([], :yes)
      assert {:ok, settled} = Resolver.settle(market.id)
      assert settled.status == :settled
    end

    test "leaves already-settled positions alone (idempotent on per-position level)" do
      market = create_active(pool: AMM.new(1_000, 1_000))
      {:ok, _} = Trader.place_position("alice", market.id, :yes, 50)

      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.submit_resolution(market.id, :yes)
      {:ok, _} = Resolver.settle(market.id)

      # All positions are now :settled_winner; none remain :open.
      positions = Store.list_positions_for_market(market.id)
      assert Enum.all?(positions, &(&1.status == :settled_winner))
    end

    test "transitions sub-threshold live disputes to :resolved_for so they're claimable" do
      :ok = EventBus.subscribe(MarketsEvents.DisputeResolved)

      market = create_active(pool: AMM.new(1_000, 1_000))
      {:ok, _} = Trader.place_position("alice", market.id, :yes, 50)
      {:ok, _} = Trader.place_position("bob", market.id, :no, 50)
      {:ok, _} = Trader.place_position("carol", market.id, :no, 50)

      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.submit_resolution(market.id, :yes)

      # Two live disputes (well below the threshold of 5). Without the
      # fix these would stay :live forever after settle and the
      # disputers' XMR would be permanently held.
      {:ok, dispute_bob} = Disputer.start_dispute("bob", market.id)
      {:ok, dispute_carol} = Disputer.start_dispute("carol", market.id)
      {:ok, _} = Disputer.confirm_deposit("bob", market.id)
      {:ok, _} = Disputer.confirm_deposit("carol", market.id)

      assert {:ok, settled} = Resolver.settle(market.id)
      assert settled.status == :settled

      {:ok, bob_after} = Store.get_dispute(dispute_bob.account_id, market.id)
      {:ok, carol_after} = Store.get_dispute(dispute_carol.account_id, market.id)
      assert bob_after.status == :resolved_for
      assert carol_after.status == :resolved_for

      market_id = market.id

      assert_receive %MarketsEvents.DisputeResolved{
                       market_id: ^market_id,
                       account_id: aid1,
                       status: :resolved_for
                     },
                     1_000

      assert_receive %MarketsEvents.DisputeResolved{
                       account_id: aid2,
                       status: :resolved_for
                     },
                     1_000

      assert MapSet.new([aid1, aid2]) == MapSet.new(["bob", "carol"])

      EventBus.unsubscribe(MarketsEvents.DisputeResolved)
    end
  end

  describe "settle/1 — errors" do
    test "errors from :active" do
      market = create_active()
      assert {:error, :invalid_transition} = Resolver.settle(market.id)
    end

    test "errors when market does not exist" do
      assert {:error, :market_not_found} = Resolver.settle("missing")
    end
  end

  describe "void/1 — happy paths" do
    test "refunds every open position and publishes MarketVoided + PositionCancelled" do
      :ok = EventBus.subscribe(MarketsEvents.MarketVoided)
      :ok = EventBus.subscribe(MarketsEvents.PositionCancelled)

      market = create_active(pool: AMM.new(1_000, 1_000))
      {:ok, alice_pos} = Trader.place_position("alice", market.id, :yes, 50)
      {:ok, bob_pos} = Trader.place_position("bob", market.id, :no, 50)

      {:ok, _} = Resolver.expire(market.id)

      assert {:ok, voided} = Resolver.void(market.id)
      assert voided.status == :voided
      assert voided.outcome == :void
      assert %DateTime{} = voided.resolved_at

      {:ok, a} = Store.get_position(alice_pos.id)
      {:ok, b} = Store.get_position(bob_pos.id)
      assert a.status == :refunded
      assert b.status == :refunded

      assert_receive %MarketsEvents.MarketVoided{market_id: id, reason: :operator}, 1_000
      assert id == market.id

      # One PositionCancelled per refunded position. Order is not
      # guaranteed; collect both deliveries before asserting.
      assert_receive %MarketsEvents.PositionCancelled{
                       position_id: pid1,
                       amount_refunded: amt1
                     },
                     1_000

      assert_receive %MarketsEvents.PositionCancelled{
                       position_id: pid2,
                       amount_refunded: amt2
                     },
                     1_000

      assert MapSet.new([pid1, pid2]) == MapSet.new([alice_pos.id, bob_pos.id])
      assert MapSet.new([amt1, amt2]) == MapSet.new([alice_pos.amount_paid, bob_pos.amount_paid])

      EventBus.unsubscribe(MarketsEvents.MarketVoided)
      EventBus.unsubscribe(MarketsEvents.PositionCancelled)
    end

    test "voids from :resolving (operator changes mind during dispute window)" do
      market = create_resolving([], :yes)
      assert {:ok, voided} = Resolver.void(market.id)
      assert voided.status == :voided
    end

    test "voids a market with no positions cleanly" do
      market = create_expired()
      assert {:ok, voided} = Resolver.void(market.id)
      assert voided.status == :voided
    end

    test "carries the supplied reason on the MarketVoided event" do
      :ok = EventBus.subscribe(MarketsEvents.MarketVoided)
      market = create_expired()

      assert {:ok, _} = Resolver.void(market.id, :creator_no_show)

      assert_receive %MarketsEvents.MarketVoided{
                       market_id: mid,
                       reason: :creator_no_show
                     },
                     500

      assert mid == market.id
      EventBus.unsubscribe(MarketsEvents.MarketVoided)
    end
  end

  describe "void/1 — errors" do
    test "errors from :pending" do
      pending = create_pending()
      assert {:error, :invalid_transition} = Resolver.void(pending.id)
    end

    test "errors from :active" do
      market = create_active()
      assert {:error, :invalid_transition} = Resolver.void(market.id)
    end

    test "errors when market does not exist" do
      assert {:error, :market_not_found} = Resolver.void("missing")
    end
  end

  describe "settle/1 — dispute-window enforcement (H12)" do
    setup do
      # Test-config default is dispute_window_seconds: 0 (disabled)
      # for tests that immediately settle. Override to a real window
      # to exercise the settle-time gate that closes the creator
      # self-dealing window: operator running Resolver.settle from
      # iex a minute after submission used to bypass the entire
      # dispute window disputers were promised.
      prior = Application.get_env(:perpwalk, :markets_scheduler, [])
      updated = Keyword.put(prior, :dispute_window_seconds, 3_600)
      Application.put_env(:perpwalk, :markets_scheduler, updated)

      on_exit(fn -> Application.put_env(:perpwalk, :markets_scheduler, prior) end)
      :ok
    end

    test "settle inside the dispute window is refused with :dispute_window_open" do
      market = create_resolving([pool: AMM.new(100, 100)], :yes)

      # `resolution_submitted_at` is ~now; dispute_window is 3600s;
      # settle immediately fails.
      assert {:error, :dispute_window_open} = Resolver.settle(market.id)

      # Row unchanged — no partial write.
      {:ok, live} = Store.get_market(market.id)
      assert live.status == :resolving
    end

    test "settle after the dispute window elapses succeeds" do
      market = create_resolving([pool: AMM.new(100, 100)], :yes)

      # Backdate submission past the window.
      past = DateTime.add(DateTime.utc_now(), -3_700, :second)
      :ok = Store.put_market(%{market | resolution_submitted_at: past})

      assert {:ok, settled} = Resolver.settle(market.id)
      assert settled.status == :settled
    end
  end
end
