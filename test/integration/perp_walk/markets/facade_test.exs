defmodule PerpWalk.Markets.FacadeIntegrationTest do
  @moduledoc "Integration tests for the Markets bounded-context facade."

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers, only: [market_opts: 1, pending_market!: 1]

  alias PerpWalk.Markets.Facade

  describe "create_market/1 + read API" do
    test "round-trips a market through the facade in :awaiting_deposit" do
      assert {:ok, market} = Facade.create_market(market_opts([]))
      assert market.status == :awaiting_deposit
      assert is_binary(market.deposit_subaddress)

      assert {:ok, fetched} = Facade.get_market(market.id)
      assert fetched.id == market.id

      assert market.id in Enum.map(Facade.list_markets(), & &1.id)

      assert market.id in Enum.map(Facade.list_markets_by_status(:awaiting_deposit), & &1.id)

      assert market.id in Enum.map(Facade.list_markets_by_category(:politics), & &1.id)
    end

    test "after confirm_deposit/1, market is :pending and listable as such" do
      market = pending_market!([])
      assert market.status == :pending
      assert market.id in Enum.map(Facade.list_markets_by_status(:pending), & &1.id)
    end
  end

  describe "cast_vote/3" do
    test "records a vote retrievable through the facade" do
      market = pending_market!([])

      assert {:ok, after_vote} = Facade.cast_vote("acct-a", market.id, :up)
      assert after_vote.reputation == 1

      assert Facade.has_voted?("acct-a", market.id)
      assert length(Facade.list_votes_for_market(market.id)) == 1
    end
  end

  describe "read-only paths return empty / not_found cleanly" do
    test "get_market on unknown id returns :not_found" do
      assert {:error, :not_found} = Facade.get_market("missing")
    end

    test "list_positions_for_account returns []" do
      assert Facade.list_positions_for_account("nobody") == []
    end
  end
end
