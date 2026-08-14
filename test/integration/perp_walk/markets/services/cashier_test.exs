defmodule PerpWalk.Markets.Services.CashierIntegrationTest do
  @moduledoc """
  Integration tests for `Cashier.claim_payout/2`.

  Cashier validates the position and enqueues a `Payout` with the
  federation — the actual Monero transfer happens asynchronously
  when 2-of-3 signing completes. These tests verify the validation
  and enqueueing behaviour. The end-to-end transition to
  `:paid_out` is exercised by `Federation.Signer` tests.
  """

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers,
    only: [activate!: 1, dispute!: 2, pending_market!: 1]

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Federation
  alias PerpWalk.Markets.{AMM, Position, Store}
  alias PerpWalk.Markets.Services.{Cashier, Resolver, Trader}

  setup do
    :ok = Federation.Store.clear()
    :ok
  end

  # Cashier validates destinations against the XMR address regex
  # (matches Federation.Rules.destination_sanity). Tests use a fixed
  # well-formed mainnet-shaped address; the on-chain effect is
  # stubbed out by Federation.Signer's test backend so the address
  # never has to be real.
  defp valid_destination, do: "4" <> String.duplicate("A", 94)

  defp active_market(opts) do
    market = pending_market!(opts)
    activate!(market)
  end

  defp settled_winner(market_pool \\ AMM.new(AMM.to_subunits(100), AMM.to_subunits(100))) do
    market = active_market(pool: market_pool)
    {:ok, position} = Trader.place_position("acct-a", market.id, :yes, 5)
    {:ok, _} = Resolver.expire(market.id)
    {:ok, _} = Resolver.submit_resolution(market.id, :yes)
    {:ok, _} = Resolver.settle(market.id)

    {:ok, refreshed} = PerpWalk.Markets.Store.get_position(position.id)
    assert refreshed.status == :settled_winner
    {market, refreshed}
  end

  defp settled_loser do
    market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
    {:ok, position} = Trader.place_position("acct-a", market.id, :no, 5)
    {:ok, _} = Resolver.expire(market.id)
    {:ok, _} = Resolver.submit_resolution(market.id, :yes)
    {:ok, _} = Resolver.settle(market.id)

    {:ok, refreshed} = PerpWalk.Markets.Store.get_position(position.id)
    assert refreshed.status == :settled_loser
    {market, refreshed}
  end

  defp refunded_position do
    market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
    {:ok, position} = Trader.place_position("acct-a", market.id, :yes, 5)
    {:ok, _} = Resolver.expire(market.id)
    {:ok, _} = Resolver.void(market.id)

    {:ok, refreshed} = PerpWalk.Markets.Store.get_position(position.id)
    assert refreshed.status == :refunded
    {market, refreshed}
  end

  describe "claim_payout/2 — winner happy path" do
    test "enqueues a winner_payout request with contracts × unit_size" do
      {market, position} = settled_winner()
      :ok = EventBus.subscribe(FederationEvents.PayoutRequested)

      destination = valid_destination()
      expected_amount = position.contracts * market.unit_size

      assert {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)

      assert request.position_id == position.id
      assert request.market_id == market.id
      assert request.account_id == position.account_id
      assert request.kind == :winner_payout
      assert request.amount_piconeros == expected_amount
      assert request.destination == destination
      assert request.status == :pending

      assert_receive %FederationEvents.PayoutRequested{
                       request_id: rid,
                       kind: :winner_payout,
                       amount_piconeros: ^expected_amount
                     },
                     500

      assert rid == request.id
    end

    test "the position stays in :settled_winner — no transition until federation submits" do
      {_, position} = settled_winner()

      {:ok, _request} = Cashier.claim_payout(position.id, position.account_id, valid_destination())

      {:ok, refreshed} = PerpWalk.Markets.Store.get_position(position.id)
      assert refreshed.status == :settled_winner
      assert refreshed.payout_txid == nil
    end

    test "the request is findable via Federation.Facade" do
      {_, position} = settled_winner()

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, valid_destination())

      assert {:ok, ^request} = Federation.Facade.get_request(request.id)
      assert request in Federation.Facade.list_requests()
      assert request in Federation.Facade.list_requests_for_position(position.id)
      assert request in Federation.Facade.list_requests_by_status(:pending)
      assert request in Federation.Facade.list_in_flight_requests()
    end
  end

  describe "claim_payout/2 — refund happy path" do
    test "enqueues a refund request with the original amount_paid" do
      {_market, position} = refunded_position()

      assert {:ok, request} = Cashier.claim_payout(position.id, position.account_id, valid_destination())

      assert request.kind == :refund
      assert request.amount_piconeros == position.amount_paid
      assert request.destination == valid_destination()
    end
  end

  describe "claim_payout/3 — ownership and idempotency" do
    test "{:error, :not_owner} when claimant_account_id is not the position owner" do
      {_, position} = settled_winner()

      assert {:error, :not_owner} =
               Cashier.claim_payout(position.id, "different-acct", "dest")
    end

    test "{:error, :payout_already_pending} when an in-flight Payout exists" do
      {_, position} = settled_winner()
      {:ok, _first} = Cashier.claim_payout(position.id, position.account_id, valid_destination())

      assert {:error, :payout_already_pending} =
               Cashier.claim_payout(position.id, position.account_id, valid_destination())
    end

    test "re-claim allowed after a Payout fails (failed is terminal-for-retry)" do
      {_, position} = settled_winner()
      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, valid_destination())

      # Simulate the federation marking the payout as :failed
      failed = %{request | status: :failed, rule_failure_reason: "test failure"}
      :ok = Federation.Store.put_payout(failed)

      # Re-claim should now succeed
      assert {:ok, _retry} =
               Cashier.claim_payout(position.id, position.account_id, valid_destination())
    end
  end

  describe "claim_payout/3 — error paths" do
    test "{:error, :position_not_found} when id is unknown" do
      assert {:error, :position_not_found} = Cashier.claim_payout("missing-id", "any-acct", "dest")
    end

    test "{:error, :not_payable} for an open position" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      {:ok, position} = Trader.place_position("acct-a", market.id, :yes, 5)

      assert {:error, :not_payable} = Cashier.claim_payout(position.id, position.account_id, valid_destination())
    end

    test "{:error, :not_payable} for a settled loser" do
      {_, position} = settled_loser()

      assert {:error, :not_payable} = Cashier.claim_payout(position.id, position.account_id, valid_destination())
    end

    test "no PayoutRequested event published on validation error" do
      :ok = EventBus.subscribe(FederationEvents.PayoutRequested)

      _ = Cashier.claim_payout("missing-id", "any-acct", "dest")

      refute_receive %FederationEvents.PayoutRequested{}, 100
    end

    test "no Payout is persisted on validation error" do
      _ = Cashier.claim_payout("missing-id", "any-acct", "dest")

      assert Federation.Facade.list_requests() == []
    end
  end

  describe "Position.pay_out/2 — state machine" do
    test "transitions :settled_winner → :paid_out with txid + paid_out_at" do
      pos = %Position{
        id: "p1",
        market_id: "m1",
        account_id: "a1",
        side: :yes,
        contracts: 1,
        amount_paid: 1_000,
        spread_piconeros: 0,
        status: :settled_winner,
        created_at: DateTime.utc_now(),
        settled_at: DateTime.utc_now()
      }

      {:ok, paid} = Position.pay_out(pos, "tx-abc")

      assert paid.status == :paid_out
      assert paid.payout_txid == "tx-abc"
      assert %DateTime{} = paid.paid_out_at
    end

    test "{:error, :already_paid_out} on a second pay_out" do
      pos = %Position{
        id: "p1",
        market_id: "m1",
        account_id: "a1",
        side: :yes,
        contracts: 1,
        amount_paid: 1_000,
        spread_piconeros: 0,
        status: :paid_out,
        created_at: DateTime.utc_now(),
        settled_at: DateTime.utc_now(),
        paid_out_at: DateTime.utc_now(),
        payout_txid: "first"
      }

      assert {:error, :already_paid_out} = Position.pay_out(pos, "second")
    end

    test "{:error, :invalid_transition} from :open or :settled_loser" do
      base = %Position{
        id: "p1",
        market_id: "m1",
        account_id: "a1",
        side: :yes,
        contracts: 1,
        amount_paid: 1_000,
        spread_piconeros: 0,
        status: :open,
        created_at: DateTime.utc_now()
      }

      assert {:error, :invalid_transition} = Position.pay_out(base, "tx")
      assert {:error, :invalid_transition} = Position.pay_out(%{base | status: :settled_loser}, "tx")
    end
  end

  describe "claim_dispute_refund/3 — full-refund happy path" do
    test "enqueues a :dispute_refund_full request for a :resolved_against dispute" do
      {market, _} = expired_with_resolution()
      live = dispute_against_resolution(market.id, "voter-1")

      :ok = EventBus.subscribe(FederationEvents.PayoutRequested)

      destination = valid_destination()

      assert {:ok, request} =
               Cashier.claim_dispute_refund("voter-1", market.id, destination)

      assert request.position_id == nil
      assert request.market_id == market.id
      assert request.account_id == "voter-1"
      assert request.kind == :dispute_refund_full
      assert request.amount_piconeros == live.stake_amount_piconeros
      assert request.destination == destination
      assert request.status == :pending

      assert_receive %FederationEvents.PayoutRequested{
                       request_id: rid,
                       position_id: nil,
                       kind: :dispute_refund_full
                     },
                     500

      assert rid == request.id
    end
  end

  describe "claim_dispute_refund/3 — partial-refund happy path" do
    test "enqueues a :dispute_refund_partial request for a :resolved_for dispute" do
      {market, _} = expired_with_resolution()
      live = dispute!("voter-1", market.id)

      # Guardians ack-confirm the creator's resolution — disputer was
      # wrong, partial slash applies, dispute → :resolved_for.
      {:ok, _} = Resolver.acknowledge_disputes(market.id)

      {:ok, refreshed} = Store.get_dispute("voter-1", market.id)
      assert refreshed.status == :resolved_for
      assert refreshed.slashed_amount_piconeros > 0
      assert refreshed.slashed_amount_piconeros < live.stake_amount_piconeros

      assert {:ok, request} =
               Cashier.claim_dispute_refund("voter-1", market.id, valid_destination())

      assert request.kind == :dispute_refund_partial

      assert request.amount_piconeros ==
               live.stake_amount_piconeros - refreshed.slashed_amount_piconeros
    end
  end

  describe "claim_dispute_refund/3 — error paths" do
    test "{:error, :dispute_not_found} when the (account, market) tuple is unknown" do
      assert {:error, :dispute_not_found} =
               Cashier.claim_dispute_refund("missing-acct", "missing-market", "dest")
    end

    test "{:error, :not_refundable} for a dispute still in :live" do
      {market, _} = expired_with_resolution()
      _ = dispute!("voter-1", market.id)

      assert {:error, :not_refundable} =
               Cashier.claim_dispute_refund("voter-1", market.id, "dest")
    end

    test "{:error, :refund_already_pending} on second claim while first is in flight" do
      {market, _} = expired_with_resolution()
      _ = dispute_against_resolution(market.id, "voter-1")

      {:ok, _first} = Cashier.claim_dispute_refund("voter-1", market.id, valid_destination())

      assert {:error, :refund_already_pending} =
               Cashier.claim_dispute_refund("voter-1", market.id, valid_destination())
    end

    test "no Payout persisted on validation error" do
      _ = Cashier.claim_dispute_refund("missing-acct", "missing-market", "dest")
      assert Federation.Facade.list_requests() == []
    end
  end

  describe "mark_dispute_refunded/2" do
    test "transitions :resolved_against → :refunded_full" do
      {market, _} = expired_with_resolution()
      _ = dispute_against_resolution(market.id, "voter-1")

      {:ok, before} = Store.get_dispute("voter-1", market.id)
      assert before.status == :resolved_against

      assert {:ok, refunded} = Cashier.mark_dispute_refunded("voter-1", market.id)
      assert refunded.status == :refunded_full
    end

    test "transitions :resolved_for → :refunded_partial" do
      {market, _} = expired_with_resolution()
      _ = dispute!("voter-1", market.id)
      {:ok, _} = Resolver.acknowledge_disputes(market.id)

      assert {:ok, refunded} = Cashier.mark_dispute_refunded("voter-1", market.id)
      assert refunded.status == :refunded_partial
    end

    test "{:error, :dispute_not_found} when the tuple is unknown" do
      assert {:error, :dispute_not_found} =
               Cashier.mark_dispute_refunded("ghost", "phantom")
    end
  end

  # --- Dispute fixtures ---

  # Active market driven into :resolving by creator submitting YES,
  # without settling. The market stays in :resolving so live
  # disputes can still be filed. Seeds a 1-contract YES position
  # for `voter-1` (the dispute fixtures use this account) — the
  # Disputer rejects accounts that haven't traded on the market.
  defp expired_with_resolution do
    market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
    {:ok, position} = Trader.place_position("acct-a", market.id, :yes, 5)
    {:ok, _} = Trader.place_position("voter-1", market.id, :yes, 1)
    {:ok, _} = Resolver.expire(market.id)
    {:ok, m} = Resolver.submit_resolution(market.id, :yes)
    {m, position}
  end

  # Files a dispute on a :resolving market, then has guardians REVERSE
  # the resolution — auto-resolves the dispute as :resolved_against
  # (full refund due, no slash).
  defp dispute_against_resolution(market_id, account_id) do
    _ = dispute!(account_id, market_id)
    {:ok, _} = Resolver.reverse_resolution(market_id, :no)
    {:ok, refreshed} = Store.get_dispute(account_id, market_id)
    assert refreshed.status == :resolved_against
    refreshed
  end

  describe "claim_creator_lp_return/3 — settled happy path" do
    test "enqueues a creator_lp_return for the winning side's residual" do
      {market, _position} = settled_winner()
      :ok = EventBus.subscribe(FederationEvents.PayoutRequested)

      destination = valid_destination()
      {:ok, settled_market} = Store.get_market(market.id)

      # Creator LP return = winning-side pool residual PLUS the
      # creator's 1/6 slice of the accumulated per-position spread.
      # Pre-fix the spread share accumulated unattributed in the
      # multisig; now included in the enqueue.
      expected_amount =
        AMM.cost_to_piconeros(settled_market.pool.yes, settled_market.unit_size) +
          Cashier.creator_spread_share(settled_market.id)

      assert {:ok, request} =
               Cashier.claim_creator_lp_return(
                 settled_market.creator_account_id,
                 settled_market.id,
                 destination
               )

      assert request.kind == :creator_lp_return
      assert request.amount_piconeros == expected_amount
      assert request.market_id == settled_market.id
      assert request.account_id == settled_market.creator_account_id
      assert request.position_id == nil
      assert request.status == :pending

      assert_receive %FederationEvents.PayoutRequested{
                       request_id: rid,
                       kind: :creator_lp_return,
                       amount_piconeros: ^expected_amount
                     },
                     1_000

      assert rid == request.id
    end
  end

  describe "claim_creator_lp_return/3 — voided happy path" do
    test "enqueues a creator_lp_return for the full deposit" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.void(market.id)
      {:ok, voided} = Store.get_market(market.id)
      assert voided.status == :voided

      destination = valid_destination()

      assert {:ok, request} =
               Cashier.claim_creator_lp_return(
                 voided.creator_account_id,
                 voided.id,
                 destination
               )

      assert request.kind == :creator_lp_return
      assert request.amount_piconeros == voided.deposit_amount
    end
  end

  describe "claim_creator_lp_return/3 — error paths" do
    test "rejects when the caller isn't the creator" do
      {market, _position} = settled_winner()

      assert {:error, :not_creator} =
               Cashier.claim_creator_lp_return("imposter", market.id, valid_destination())
    end

    test "rejects when the market hasn't reached :settled or :voided" do
      m = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))

      assert {:error, :market_not_returnable} =
               Cashier.claim_creator_lp_return(m.creator_account_id, m.id, valid_destination())
    end

    test "rejects a second concurrent claim with :lp_return_already_pending" do
      {market, _} = settled_winner()
      {:ok, settled_market} = Store.get_market(market.id)

      {:ok, _request} =
        Cashier.claim_creator_lp_return(
          settled_market.creator_account_id,
          settled_market.id,
          valid_destination()
        )

      assert {:error, :lp_return_already_pending} =
               Cashier.claim_creator_lp_return(
                 settled_market.creator_account_id,
                 settled_market.id,
                 valid_destination()
               )
    end
  end
end
