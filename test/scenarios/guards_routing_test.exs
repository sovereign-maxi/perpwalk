defmodule PerpWalk.Scenarios.GuardsRoutingTest do
  @moduledoc """
  Scenario: every Markets-service mutation entry point routes
  through `PerpWalk.Guards.ensure_operational!/0`. We pick one
  canonical entry per service and verify the raise propagates.

  Drives the halt via `Telemetry.Health.System.set_halted/1` because
  the persistent_term flip is what `Guards` actually reads — the path
  is identical for auto-halts (federation_quorum_lost) and manual
  halts at the Guards layer.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import PerpWalk.TestHelpers.CleanState, only: [clean_state: 1]

  import PerpWalk.TestHelpers.MarketsHelpers,
    only: [activate!: 1, build_market: 1, pending_market!: 1]

  alias PerpWalk.Guards.SystemHaltedError
  alias PerpWalk.Markets.{AMM, Store}
  alias PerpWalk.Markets.Services.{Cashier, Disputer, Maker, Resolver, Trader, Voter}
  alias PerpWalk.Telemetry.Health.System, as: HealthSystem

  setup :clean_state

  setup do
    on_exit(&HealthSystem.clear_halt/0)

    :ok
  end

  defp active_market(opts \\ []) do
    market = build_market(Keyword.merge([pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100))], opts))
    :ok = Store.put_market(market)
    activate!(market)
  end

  describe "halt blocks every Markets-service mutation entry" do
    test "Maker.create_market/1 raises" do
      HealthSystem.set_halted("test")

      assert_raise SystemHaltedError, fn ->
        Maker.create_market(
          description: "desc",
          resolution_criterion: "criterion that is long enough to satisfy the validator",
          category: :crypto,
          expiry: DateTime.add(DateTime.utc_now(), 86_400, :second),
          creator_account_id: "acct-a"
        )
      end
    end

    test "Maker.confirm_deposit/1 raises" do
      market = pending_market!([])
      HealthSystem.set_halted("test")

      assert_raise SystemHaltedError, fn ->
        Maker.confirm_deposit(market.id)
      end
    end

    test "Trader.place_position/4 raises" do
      market = active_market()
      HealthSystem.set_halted("test")

      assert_raise SystemHaltedError, fn ->
        Trader.place_position("acct-a", market.id, :yes, 1)
      end
    end

    test "Trader.create_quote/5 raises" do
      market = active_market()
      HealthSystem.set_halted("test")

      assert_raise SystemHaltedError, fn ->
        Trader.create_quote("acct-a", market.id, :yes, 1,
          refund_address: PerpWalk.TestHelpers.MarketsHelpers.refund_address_stub()
        )
      end
    end

    test "Voter.cast_vote/3 raises" do
      market = pending_market!([])
      HealthSystem.set_halted("test")

      assert_raise SystemHaltedError, fn ->
        Voter.cast_vote("acct-a", market.id, :up)
      end
    end

    test "Disputer.start_dispute/3 raises" do
      market = pending_market!([])
      HealthSystem.set_halted("test")

      assert_raise SystemHaltedError, fn ->
        Disputer.start_dispute("acct-a", market.id)
      end
    end

    test "Resolver.activate/1 raises" do
      market = pending_market!([])
      HealthSystem.set_halted("test")

      assert_raise SystemHaltedError, fn ->
        Resolver.activate(market.id)
      end
    end

    test "Resolver.submit_resolution/2 raises" do
      market = active_market()
      HealthSystem.set_halted("test")

      assert_raise SystemHaltedError, fn ->
        Resolver.submit_resolution(market.id, :yes)
      end
    end

    test "Resolver.settle/1 raises" do
      market = active_market()
      HealthSystem.set_halted("test")

      assert_raise SystemHaltedError, fn ->
        Resolver.settle(market.id)
      end
    end

    test "Resolver.void/2 raises" do
      market = active_market()
      HealthSystem.set_halted("test")

      assert_raise SystemHaltedError, fn ->
        Resolver.void(market.id)
      end
    end

    test "Cashier.claim_payout/3 raises" do
      HealthSystem.set_halted("test")

      assert_raise SystemHaltedError, fn ->
        Cashier.claim_payout("pos-x", "acct-a", "4-monero-addr")
      end
    end

    test "Cashier.claim_dispute_refund/3 raises" do
      HealthSystem.set_halted("test")

      assert_raise SystemHaltedError, fn ->
        Cashier.claim_dispute_refund("acct-a", "m-x", "4-monero-addr")
      end
    end

    test "Cashier.claim_creator_lp_return/3 raises" do
      HealthSystem.set_halted("test")

      assert_raise SystemHaltedError, fn ->
        Cashier.claim_creator_lp_return("acct-a", "m-x", "4-monero-addr")
      end
    end
  end

  describe "scheduler" do
    alias PerpWalk.Markets.Scheduler

    test "Scheduler.run_now/0 is a no-op when the system is halted" do
      market = pending_market!([])
      backdated = %{market | deposit_confirmed_at: DateTime.add(DateTime.utc_now(), -86_500, :second)}
      :ok = Store.put_market(backdated)

      HealthSystem.set_halted("test")

      :ok = Scheduler.run_now()

      {:ok, refreshed} = Store.get_market(market.id)
      assert refreshed.status == :pending
    end

    test "Scheduler.run_now/0 proceeds normally once the halt is cleared" do
      market = pending_market!([])
      backdated = %{market | deposit_confirmed_at: DateTime.add(DateTime.utc_now(), -86_500, :second)}
      :ok = Store.put_market(backdated)

      HealthSystem.set_halted("test")
      :ok = Scheduler.run_now()
      HealthSystem.clear_halt()

      :ok = Scheduler.run_now()

      {:ok, refreshed} = Store.get_market(market.id)
      assert refreshed.status == :active
    end
  end
end
