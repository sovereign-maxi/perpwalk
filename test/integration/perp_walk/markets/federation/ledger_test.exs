defmodule PerpWalk.Markets.Federation.LedgerIntegrationTest do
  @moduledoc """
  Drives the Markets domain through dispute slashes and market
  rejections, asserting that the federation-revenue ledger sums
  correctly. Uses the real Store + Resolver + Voter pipeline so the
  derivation is exercised end-to-end.
  """

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers,
    only: [activate!: 1, dispute!: 2, pending_market!: 1]

  alias PerpWalk.Markets.{Facade, Store}
  alias PerpWalk.Markets.Federation.Ledger
  alias PerpWalk.Markets.Services.{Resolver, Trader, Voter}

  describe "breakdown/0" do
    test "returns zeros on a fresh store" do
      assert %{
               total_piconeros: 0,
               slashed_piconeros: 0,
               burned_piconeros: 0,
               slash_count: 0,
               burn_count: 0
             } = Ledger.breakdown()
    end

    test "sums slashed dispute stakes from :resolved_for disputes" do
      market = pending_market!([]) |> activate!()
      {:ok, _} = Trader.place_position("acct-a", market.id, :yes, 5)
      {:ok, _} = Trader.place_position("voter-1", market.id, :yes, 1)
      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.submit_resolution(market.id, :yes)

      _ = dispute!("voter-1", market.id)
      {:ok, _} = Resolver.acknowledge_disputes(market.id)

      {:ok, dispute} = Store.get_dispute("voter-1", market.id)
      assert dispute.status == :resolved_for
      assert dispute.slashed_amount_piconeros > 0

      breakdown = Ledger.breakdown()
      assert breakdown.slashed_piconeros == dispute.slashed_amount_piconeros
      assert breakdown.slash_count == 1
      assert breakdown.burned_piconeros == 0
      assert breakdown.total_piconeros == dispute.slashed_amount_piconeros
    end

    test "ignores :resolved_against disputes (no slash applied)" do
      market = pending_market!([]) |> activate!()
      {:ok, _} = Trader.place_position("acct-a", market.id, :yes, 5)
      {:ok, _} = Trader.place_position("voter-1", market.id, :yes, 1)
      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.submit_resolution(market.id, :yes)

      _ = dispute!("voter-1", market.id)
      {:ok, _} = Resolver.reverse_resolution(market.id, :no)

      {:ok, dispute} = Store.get_dispute("voter-1", market.id)
      assert dispute.status == :resolved_against
      assert dispute.slashed_amount_piconeros == 0

      assert %{slash_count: 0, slashed_piconeros: 0} = Ledger.breakdown()
    end

    test "sums burned creator deposits from :rejected markets" do
      market = pending_market!([])

      # 6 unanimous downvotes crosses the Wilson 0.6 lower bound,
      # rejects the market, and burns the creator's deposit.
      Enum.each(1..6, fn i ->
        {:ok, _} = Voter.cast_vote("voter-#{i}", market.id, :down)
      end)

      {:ok, refreshed} = Store.get_market(market.id)
      assert refreshed.status == :rejected

      assert %{
               burned_piconeros: burned,
               burn_count: 1,
               total_piconeros: total
             } = Ledger.breakdown()

      assert burned == market.deposit_amount
      assert total == burned
    end

    test "combines slashes and burns in the total" do
      market_a = pending_market!([]) |> activate!()
      {:ok, _} = Trader.place_position("acct-a", market_a.id, :yes, 5)
      {:ok, _} = Trader.place_position("voter-1", market_a.id, :yes, 1)
      {:ok, _} = Resolver.expire(market_a.id)
      {:ok, _} = Resolver.submit_resolution(market_a.id, :yes)

      _ = dispute!("voter-1", market_a.id)
      {:ok, _} = Resolver.acknowledge_disputes(market_a.id)

      {:ok, dispute_a} = Store.get_dispute("voter-1", market_a.id)

      market_b = pending_market!(description: "Rejected market")

      Enum.each(1..6, fn i ->
        {:ok, _} = Voter.cast_vote("voter-r#{i}", market_b.id, :down)
      end)

      breakdown = Ledger.breakdown()
      assert breakdown.slashed_piconeros == dispute_a.slashed_amount_piconeros
      assert breakdown.burned_piconeros == market_b.deposit_amount

      assert breakdown.total_piconeros ==
               dispute_a.slashed_amount_piconeros + market_b.deposit_amount

      assert breakdown.slash_count == 1
      assert breakdown.burn_count == 1
    end
  end

  describe "Facade.federation_ledger/0" do
    test "delegates to Ledger.breakdown/0" do
      assert Facade.federation_ledger() == Ledger.breakdown()
    end
  end
end
