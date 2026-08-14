defmodule PerpWalk.Markets.Services.VoterIntegrationTest do
  @moduledoc "Integration tests for PerpWalk.Markets.Services.Voter."

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers, only: [pending_market!: 1]

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.{Moderation, Store, Vote}
  alias PerpWalk.Markets.Services.Voter

  defp create_market(creator \\ "creator-hash") do
    market = pending_market!(creator_account_id: creator)
    market
  end

  describe "cast_vote/3 — success paths" do
    test "records an :up vote and updates reputation on the market" do
      market = create_market()

      assert {:ok, updated} = Voter.cast_vote("acct-a", market.id, :up)
      assert updated.reputation == 1
      assert updated.status == :pending

      assert Store.has_voted?("acct-a", market.id)
      {:ok, stored} = Store.get_market(market.id)
      assert stored.reputation == 1
    end

    test "records a :down vote and updates reputation" do
      market = create_market()

      assert {:ok, updated} = Voter.cast_vote("acct-a", market.id, :down)
      assert updated.reputation == -1
    end

    test "second vote from same account overwrites the first" do
      market = create_market()

      {:ok, _} = Voter.cast_vote("acct-a", market.id, :up)
      {:ok, after_change} = Voter.cast_vote("acct-a", market.id, :down)

      assert after_change.reputation == -1
      assert length(Store.list_votes_for_market(market.id)) == 1
    end

    test "two distinct accounts each contribute" do
      market = create_market()

      {:ok, _} = Voter.cast_vote("acct-a", market.id, :up)
      {:ok, after_b} = Voter.cast_vote("acct-b", market.id, :up)

      assert after_b.reputation == 2
    end
  end

  describe "cast_vote/3 — burn threshold" do
    # Wilson lower bound on 6/6 unanimous downvotes crosses the
    # default 0.6 cutoff, so 6 is the minimum unanimous-downvote
    # count that triggers a burn. 5/5 stays below 0.566.
    @burn_trigger_downvotes 6
    @below_burn_downvotes 5

    test "rejects market and publishes MarketRejected + DepositBurned at threshold" do
      :ok = EventBus.subscribe(MarketsEvents.MarketRejected)
      :ok = EventBus.subscribe(MarketsEvents.DepositBurned)

      market = create_market()

      result =
        Enum.reduce(1..@burn_trigger_downvotes, nil, fn n, _acc ->
          {:ok, m} = Voter.cast_vote("voter-#{n}", market.id, :down)
          m
        end)

      assert result.status == :rejected
      assert result.reputation == -@burn_trigger_downvotes

      assert_receive %MarketsEvents.MarketRejected{
                       market_id: id,
                       reputation: rep
                     },
                     1_000

      assert id == market.id
      assert rep == -@burn_trigger_downvotes

      assert_receive %MarketsEvents.DepositBurned{
                       market_id: ^id,
                       amount: amount
                     },
                     1_000

      assert amount == market.deposit_amount

      {:ok, persisted} = Store.get_market(market.id)
      assert persisted.status == :rejected

      EventBus.unsubscribe(MarketsEvents.MarketRejected)
      EventBus.unsubscribe(MarketsEvents.DepositBurned)
    end

    test "below threshold does not reject" do
      :ok = EventBus.subscribe(MarketsEvents.MarketRejected)

      market = create_market()

      Enum.each(1..@below_burn_downvotes, fn n ->
        {:ok, _} = Voter.cast_vote("voter-#{n}", market.id, :down)
      end)

      refute_receive %MarketsEvents.MarketRejected{}, 100

      {:ok, stored} = Store.get_market(market.id)
      assert stored.status == :pending
      assert stored.reputation == -@below_burn_downvotes

      EventBus.unsubscribe(MarketsEvents.MarketRejected)
    end

    test "Wilson sanity — 5 unanimous downs are tracked but don't burn" do
      # Confirms the Wilson lower bound is what's gating the
      # decision: with 5/5 down (lower bound ~0.566), the market
      # stays :pending even though the old net-N rule would have
      # burned at the same vote pattern.
      market = create_market()

      Enum.each(1..5, fn n ->
        {:ok, _} = Voter.cast_vote("voter-#{n}", market.id, :down)
      end)

      refute Moderation.burn?(Store.list_votes_for_market(market.id))

      {:ok, stored} = Store.get_market(market.id)
      assert stored.status == :pending
    end
  end

  describe "cast_vote/3 — error paths" do
    test "errors when market does not exist" do
      assert {:error, :market_not_found} =
               Voter.cast_vote("acct-a", "missing-id", :up)
    end

    test "errors when market is not :pending" do
      market = create_market()

      # 6 unanimous downvotes crosses the Wilson 0.6 lower bound and
      # transitions the market to :rejected. A subsequent up vote
      # is then refused.
      Enum.each(1..6, fn n ->
        {:ok, _} = Voter.cast_vote("voter-#{n}", market.id, :down)
      end)

      assert {:error, :market_not_pending} =
               Voter.cast_vote("late-voter", market.id, :up)
    end

    test "errors when the creator tries to vote on their own market" do
      market = create_market("creator-hash")

      assert {:error, :creator_cannot_vote} =
               Voter.cast_vote("creator-hash", market.id, :up)
    end

    test "up-vote stuffing to the cap does not freeze the down-vote burn path" do
      market = create_market()

      # An attacker rotating fresh accounts stuffs the :up bucket to
      # the per-direction cap. Inserted directly — driving cast_vote/3
      # 10k times would re-tally on every vote (O(n²)).
      for i <- 1..10_000 do
        :ok = Store.put_vote(Vote.new("stuffer-#{i}", market.id, :up))
      end

      # The :up bucket is full for fresh accounts…
      assert {:error, :market_vote_cap_reached} = Voter.cast_vote("fresh-up", market.id, :up)

      # …but :down keeps its own headroom, so the community burn path
      # stays reachable.
      assert {:ok, _} = Voter.cast_vote("fresh-down", market.id, :down)
    end
  end

  describe "commit_market_rejection activation-race defense" do
    test "refuses transition when live status is :active (not :pending or :rejected)" do
      # Pre-fix: commit_market_rejection only checked for
      # `:rejected` (idempotent no-op) and blindly wrote otherwise.
      # A voter's rejection tally accumulated against a `:pending`
      # snapshot; if activation happened between that snapshot and
      # the commit, the store overwrote `:active` with `:rejected`.
      # The creator's ≥1 XMR deposit burned AND any opened
      # positions were stranded `:open` forever (`Market.void`
      # only accepts `:expired | :resolving`). Fix: refuse
      # transition unless live status is `:pending`.
      market = create_market()

      {:ok, pending} = Store.get_market(market.id)
      activated = %{pending | status: :active, activated_at: DateTime.utc_now()}
      :ok = Store.put_market(activated)

      rejected_snapshot = %{pending | status: :rejected}

      assert {:error, {:not_rejectable, :active}} =
               Store.commit_market_rejection(rejected_snapshot)

      # Live row unchanged.
      {:ok, live} = Store.get_market(market.id)
      assert live.status == :active
    end

    test "refuses transition when market is :expired" do
      market = create_market()

      {:ok, pending} = Store.get_market(market.id)
      expired = %{pending | status: :expired}
      :ok = Store.put_market(expired)

      rejected_snapshot = %{pending | status: :rejected}

      assert {:error, {:not_rejectable, :expired}} =
               Store.commit_market_rejection(rejected_snapshot)
    end

    test "returns :market_not_found when the market has been cleared" do
      market = create_market()
      :ok = Store.clear()

      rejected_snapshot = %{market | status: :rejected}

      assert {:error, :market_not_found} =
               Store.commit_market_rejection(rejected_snapshot)
    end

    test "accepts transition on :pending → :rejected (happy path)" do
      market = create_market()

      {:ok, pending} = Store.get_market(market.id)
      rejected_snapshot = %{pending | status: :rejected}

      assert {:ok, :transitioned} = Store.commit_market_rejection(rejected_snapshot)

      {:ok, live} = Store.get_market(market.id)
      assert live.status == :rejected
    end

    test "idempotent when already :rejected" do
      market = create_market()

      {:ok, pending} = Store.get_market(market.id)
      rejected_snapshot = %{pending | status: :rejected}

      assert {:ok, :transitioned} = Store.commit_market_rejection(rejected_snapshot)
      assert {:ok, :already_rejected} = Store.commit_market_rejection(rejected_snapshot)
    end
  end
end
