defmodule PerpWalk.Markets.Services.DisputerIntegrationTest do
  @moduledoc """
  Integration tests for the dispute-flag flow. Drives markets through
  the lifecycle into `:resolving`, then asserts the Disputer's
  validation gates and the threshold-trigger mechanic.
  """

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers,
    only: [dispute!: 2, pending_market!: 1]

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.{Dispute, Facade, Moderation, Store}
  alias PerpWalk.Markets.Services.{Disputer, Resolver, Trader}

  setup do
    :ok = EventBus.subscribe(MarketsEvents.DisputeFlagged)
    :ok = EventBus.subscribe(MarketsEvents.DisputeReReviewTriggered)
    :ok = EventBus.subscribe(MarketsEvents.DisputesAcknowledged)
    :ok
  end

  # Default trader set is generous enough to cover the patterns this
  # file uses (`voter-1`..`voter-20`, `voter-floor`). Disputer now
  # requires the disputer to have traded on the market; seeding
  # 1-contract YES positions for each potential voter keeps the
  # tests focused on dispute mechanics rather than the trade
  # precondition. Tests that specifically exercise the
  # `must_have_traded_on_market` refusal use a fresh account.
  @default_traders ~w(voter-floor voter-1 voter-2 voter-3 voter-4 voter-5 voter-6 voter-7 voter-8 voter-9 voter-10 voter-11 voter-12 voter-13 voter-14 voter-15 voter-16 voter-17 voter-18 voter-19 voter-20)

  defp resolving_market!(opts \\ []) do
    market = pending_market!(opts)
    {:ok, _} = Resolver.activate(market.id)
    traders = Keyword.get(opts, :traders, @default_traders)
    Enum.each(traders, &({:ok, _} = Trader.place_position(&1, market.id, :yes, 1)))
    {:ok, _} = Resolver.expire(market.id)
    {:ok, m} = Resolver.submit_resolution(market.id, :yes)
    m
  end

  describe "start_dispute/3" do
    test "creates an :awaiting_deposit dispute with subaddress + stake" do
      m = resolving_market!()

      assert {:ok, dispute} = Disputer.start_dispute("voter-1", m.id)
      assert dispute.status == :awaiting_deposit
      assert dispute.account_id == "voter-1"
      assert dispute.market_id == m.id
      assert dispute.stake_amount_piconeros >= 100_000_000_000
      assert is_binary(dispute.deposit_subaddress)
      assert is_integer(dispute.deposit_subaddress_index)

      assert Facade.has_flagged?("voter-1", m.id)
      # Total dispute count includes :awaiting_deposit.
      assert Facade.dispute_count(m.id) == 1
      # Live count excludes it.
      assert Facade.live_dispute_count(m.id) == 0
    end

    test "is idempotent — second start from same account returns the existing dispute" do
      m = resolving_market!()

      assert {:ok, first} = Disputer.start_dispute("voter-1", m.id)
      assert {:ok, second} = Disputer.start_dispute("voter-1", m.id)

      assert first.deposit_subaddress == second.deposit_subaddress
      assert first.deposit_subaddress_index == second.deposit_subaddress_index
      assert Facade.dispute_count(m.id) == 1
    end

    test "rejects when market is not :resolving" do
      pending = pending_market!([])

      assert {:error, :market_not_resolving} = Disputer.start_dispute("voter-1", pending.id)
    end

    test "rejects when market does not exist" do
      assert {:error, :market_not_found} =
               Disputer.start_dispute("voter-1", "nonexistent-market-id")
    end

    test "rejects when the creator tries to dispute their own market" do
      m = resolving_market!(creator_account_id: "creator-x")

      assert {:error, :creator_cannot_dispute_own_market} =
               Disputer.start_dispute("creator-x", m.id)
    end

    test "rejects when the disputing account has not traded on the market" do
      # `resolving_market!` seeds positions for the default voter set
      # but not for `non-trader`, so this account has no standing.
      m = resolving_market!()

      assert {:error, :must_have_traded_on_market} =
               Disputer.start_dispute("non-trader", m.id)
    end

    test "stake is 10% of the creator's initial liquidity" do
      # Default helper deposit is 1 XMR → stake is 0.1 XMR regardless
      # of traded volume on the market.
      m = resolving_market!()
      assert {:ok, dispute} = Disputer.start_dispute("voter-floor", m.id)
      assert dispute.stake_amount_piconeros == 100_000_000_000
    end
  end

  describe "confirm_deposit/2" do
    test "transitions :awaiting_deposit → :live and bumps the live count" do
      m = resolving_market!()
      {:ok, _} = Disputer.start_dispute("voter-1", m.id)

      assert Facade.live_dispute_count(m.id) == 0

      assert {:ok, live} = Disputer.confirm_deposit("voter-1", m.id)
      assert live.status == :live
      assert %DateTime{} = live.deposit_confirmed_at

      assert Facade.live_dispute_count(m.id) == 1
    end

    test "publishes DisputeFlagged with the live count" do
      m = resolving_market!()
      {:ok, _} = Disputer.start_dispute("voter-1", m.id)
      {:ok, _} = Disputer.confirm_deposit("voter-1", m.id)

      assert_receive %MarketsEvents.DisputeFlagged{
        market_id: market_id,
        account_id: "voter-1",
        dispute_count: 1
      }

      assert market_id == m.id
    end

    test "is idempotent on an already-:live dispute" do
      m = resolving_market!()
      {:ok, _} = Disputer.start_dispute("voter-1", m.id)
      {:ok, _} = Disputer.confirm_deposit("voter-1", m.id)
      assert {:ok, %{status: :live}} = Disputer.confirm_deposit("voter-1", m.id)
      assert Facade.live_dispute_count(m.id) == 1
    end

    test "publishes DisputeReReviewTriggered exactly once when live threshold crossed" do
      m = resolving_market!()
      threshold = Moderation.default_dispute_threshold()

      Enum.each(1..threshold, fn i ->
        _ = dispute!("voter-#{i}", m.id)
      end)

      assert_receive %MarketsEvents.DisputeReReviewTriggered{
        dispute_count: ^threshold,
        threshold: ^threshold
      }

      # One more confirmed dispute should NOT retrigger.
      _ = dispute!("voter-#{threshold + 1}", m.id)
      refute_receive %MarketsEvents.DisputeReReviewTriggered{}, 100
    end

    test "unfunded disputes do NOT count toward the threshold" do
      m = resolving_market!()
      threshold = Moderation.default_dispute_threshold()

      # Start `threshold` disputes without confirming any of them.
      Enum.each(1..threshold, fn i ->
        {:ok, _} = Disputer.start_dispute("voter-#{i}", m.id)
      end)

      # No re-review should trigger because none are :live yet.
      refute_receive %MarketsEvents.DisputeReReviewTriggered{}, 100
      assert Facade.live_dispute_count(m.id) == 0
    end
  end

  describe "cancel_pending/2" do
    test "transitions :awaiting_deposit → :cancelled" do
      m = resolving_market!()
      {:ok, dispute} = Disputer.start_dispute("voter-1", m.id)
      assert dispute.status == :awaiting_deposit

      assert {:ok, cancelled} = Disputer.cancel_pending("voter-1", m.id)
      assert cancelled.status == :cancelled
      assert %DateTime{} = cancelled.resolved_at
    end

    test "is idempotent on an already-:cancelled record" do
      m = resolving_market!()
      {:ok, _} = Disputer.start_dispute("voter-1", m.id)
      {:ok, _} = Disputer.cancel_pending("voter-1", m.id)

      assert {:ok, %{status: :cancelled}} = Disputer.cancel_pending("voter-1", m.id)
    end

    test "refuses to cancel a funded (:live) dispute" do
      m = resolving_market!()
      {:ok, _} = Disputer.start_dispute("voter-1", m.id)
      {:ok, _} = Disputer.confirm_deposit("voter-1", m.id)

      assert {:error, :invalid_transition} = Disputer.cancel_pending("voter-1", m.id)
    end

    test "returns :dispute_not_found when no dispute exists" do
      m = resolving_market!()
      assert {:error, :dispute_not_found} = Disputer.cancel_pending("noone", m.id)
    end

    test "cancelled dispute does not count toward threshold or live count" do
      m = resolving_market!()
      {:ok, _} = Disputer.start_dispute("voter-1", m.id)
      assert Facade.live_dispute_count(m.id) == 0

      {:ok, _} = Disputer.cancel_pending("voter-1", m.id)
      assert Facade.live_dispute_count(m.id) == 0
      refute Facade.has_flagged?("voter-1", m.id)
    end

    test "user can re-flag the same market after cancelling" do
      m = resolving_market!()
      {:ok, first} = Disputer.start_dispute("voter-1", m.id)
      {:ok, _} = Disputer.cancel_pending("voter-1", m.id)

      assert {:ok, second} = Disputer.start_dispute("voter-1", m.id)
      assert second.status == :awaiting_deposit
      # New subaddress allocation — fresh deposit destination.
      assert second.deposit_subaddress != first.deposit_subaddress
    end
  end

  describe "settle blocking on unacknowledged disputes" do
    test "settle refuses past threshold without acknowledgement" do
      m = resolving_market!()
      threshold = Moderation.default_dispute_threshold()

      Enum.each(1..threshold, fn i ->
        _ = dispute!("voter-#{i}", m.id)
      end)

      assert {:error, :unacknowledged_disputes} = Resolver.settle(m.id)
    end

    test "settle proceeds when disputes below threshold" do
      m = resolving_market!()
      threshold = Moderation.default_dispute_threshold()

      Enum.each(1..(threshold - 1), fn i ->
        _ = dispute!("voter-#{i}", m.id)
      end)

      assert {:ok, settled} = Resolver.settle(m.id)
      assert settled.status == :settled
    end

    test "acknowledge_disputes clears the gate" do
      m = resolving_market!()
      threshold = Moderation.default_dispute_threshold()

      Enum.each(1..threshold, fn i ->
        _ = dispute!("voter-#{i}", m.id)
      end)

      assert {:error, :unacknowledged_disputes} = Resolver.settle(m.id)

      assert {:ok, ack_market} = Resolver.acknowledge_disputes(m.id)
      assert ack_market.disputes_acknowledged_count == threshold

      assert_receive %MarketsEvents.DisputesAcknowledged{acknowledged_count: ^threshold}

      assert {:ok, settled} = Resolver.settle(m.id)
      assert settled.status == :settled
    end

    test "reverse_resolution implicitly acknowledges disputes" do
      m = resolving_market!()
      threshold = Moderation.default_dispute_threshold()

      Enum.each(1..threshold, fn i ->
        _ = dispute!("voter-#{i}", m.id)
      end)

      assert {:ok, reversed} = Resolver.reverse_resolution(m.id, :no)
      assert reversed.outcome == :no
      assert reversed.disputes_acknowledged_count == threshold

      assert {:ok, _settled} = Resolver.settle(m.id)
    end

    test "acknowledge transitions live disputes to :resolved_for with slash applied" do
      m = resolving_market!()
      threshold = Moderation.default_dispute_threshold()

      :ok = EventBus.subscribe(MarketsEvents.DisputeResolved)

      disputes = Enum.map(1..threshold, fn i -> dispute!("voter-#{i}", m.id) end)
      stake = hd(disputes).stake_amount_piconeros
      expected_slash = Moderation.slash_amount(stake)
      expected_refund = stake - expected_slash

      {:ok, _} = Resolver.acknowledge_disputes(m.id)

      Enum.each(disputes, fn d ->
        {:ok, after_resolve} = Store.get_dispute(d.account_id, d.market_id)
        assert after_resolve.status == :resolved_for
        assert after_resolve.slashed_amount_piconeros == expected_slash
        assert %DateTime{} = after_resolve.resolved_at
      end)

      account_ids =
        for _ <- 1..threshold do
          assert_receive %MarketsEvents.DisputeResolved{
                           status: :resolved_for,
                           refund_amount_piconeros: ^expected_refund,
                           slashed_amount_piconeros: ^expected_slash,
                           account_id: account_id
                         },
                         200

          account_id
        end

      assert Enum.sort(account_ids) ==
               Enum.sort(for i <- 1..threshold, do: "voter-#{i}")
    end

    test "reverse transitions live disputes to :resolved_against with full refund" do
      m = resolving_market!()
      threshold = Moderation.default_dispute_threshold()

      :ok = EventBus.subscribe(MarketsEvents.DisputeResolved)

      disputes = Enum.map(1..threshold, fn i -> dispute!("voter-#{i}", m.id) end)
      stake = hd(disputes).stake_amount_piconeros

      {:ok, _} = Resolver.reverse_resolution(m.id, :no)

      Enum.each(disputes, fn d ->
        {:ok, after_resolve} = Store.get_dispute(d.account_id, d.market_id)
        assert after_resolve.status == :resolved_against
        assert after_resolve.slashed_amount_piconeros == 0
      end)

      for _ <- 1..threshold do
        assert_receive %MarketsEvents.DisputeResolved{
                         status: :resolved_against,
                         refund_amount_piconeros: ^stake,
                         slashed_amount_piconeros: 0
                       },
                       200
      end
    end

    test "void from :resolving resolves live disputes as :resolved_against" do
      m = resolving_market!()
      d = dispute!("voter-1", m.id)
      stake = d.stake_amount_piconeros

      {:ok, _voided} = Resolver.void(m.id)

      {:ok, after_void} = Store.get_dispute("voter-1", m.id)
      assert after_void.status == :resolved_against
      assert Dispute.refund_amount_piconeros(after_void) == stake
    end

    test "fresh disputes past threshold after acknowledgement re-block settle" do
      m = resolving_market!()
      threshold = Moderation.default_dispute_threshold()

      Enum.each(1..threshold, fn i ->
        _ = dispute!("voter-#{i}", m.id)
      end)

      {:ok, _} = Resolver.acknowledge_disputes(m.id)

      # Add `threshold` more fresh disputes from new accounts.
      Enum.each((threshold + 1)..(threshold * 2), fn i ->
        _ = dispute!("voter-#{i}", m.id)
      end)

      assert {:error, :unacknowledged_disputes} = Resolver.settle(m.id)
    end

    test "re-review event fires as the fresh cohort crosses the threshold post-ack" do
      m = resolving_market!()
      threshold = Moderation.default_dispute_threshold()

      Enum.each(1..threshold, fn i ->
        _ = dispute!("voter-#{i}", m.id)
      end)

      {:ok, _} = Resolver.acknowledge_disputes(m.id)

      # The fresh cohort must re-trigger the page at the threshold —
      # a full acknowledgement cycle earlier and the scheduler would
      # auto-void with nobody paged.
      Enum.each((threshold + 1)..(threshold * 2), fn i ->
        _ = dispute!("voter-#{i}", m.id)
      end)

      assert_receive %MarketsEvents.DisputeReReviewTriggered{market_id: mid}, 500
      assert mid == m.id
    end
  end

  describe "acknowledge_disputes/1" do
    test "rejects when market is not :resolving" do
      pending = pending_market!([])
      assert {:error, :market_not_resolving} = Resolver.acknowledge_disputes(pending.id)
    end

    test "is idempotent on a market with no disputes" do
      m = resolving_market!()

      assert {:ok, ack1} = Resolver.acknowledge_disputes(m.id)
      assert ack1.disputes_acknowledged_count == 0

      assert {:ok, ack2} = Resolver.acknowledge_disputes(m.id)
      assert ack2.disputes_acknowledged_count == 0
    end
  end
end
