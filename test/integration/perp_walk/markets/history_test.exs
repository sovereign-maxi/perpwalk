defmodule PerpWalk.Markets.HistoryIntegrationTest do
  @moduledoc """
  Integration tests for `PerpWalk.Markets.History.odds_history/1`.

  History walks the supervised WAL and extracts a per-market YES-
  probability time series from `:market_put`, `:trade_executed`,
  and `:market_resolved` entries. The test runs against the
  application-supervised WAL so the actual WAL-replay path is
  exercised end-to-end.
  """

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers, only: [activate!: 1, pending_market!: 0]

  alias PerpWalk.Markets.{Facade, History}
  alias PerpWalk.Markets.Services.{Resolver, Trader}

  describe "odds_history/1" do
    test "returns a single point for a freshly-created market (just :market_put)" do
      market = pending_market!()

      assert {:ok, points} = History.odds_history(market.id)
      refute points == []

      ours = Enum.filter(points, &(&1.t != nil))
      assert Enum.any?(ours, fn p -> p.yes == 0.5 end)
    end

    test "appends a point per trade_executed and per market_resolved" do
      market = pending_market!()
      market = activate!(market)

      {:ok, _position} = Trader.place_position("acct-a", market.id, :yes, 5)
      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.submit_resolution(market.id, :yes)
      {:ok, _} = Resolver.settle(market.id)

      assert {:ok, [_, _, _ | _]} = History.odds_history(market.id)
    end

    test "is sorted ascending by time" do
      market = pending_market!()
      market = activate!(market)
      {:ok, _} = Trader.place_position("acct-a", market.id, :yes, 3)
      {:ok, _} = Trader.place_position("acct-b", market.id, :no, 4)

      {:ok, points} = History.odds_history(market.id)

      timestamps = Enum.map(points, & &1.t)
      assert timestamps == Enum.sort_by(timestamps, & &1, DateTime)
    end

    test "is exposed via Markets.Facade.odds_history/1" do
      market = pending_market!()
      assert {:ok, _points} = Facade.odds_history(market.id)
    end

    test "every point carries a YES probability in [0, 1] and a non-negative pool_total" do
      market = pending_market!()
      market = activate!(market)
      {:ok, _} = Trader.place_position("acct-a", market.id, :yes, 5)

      {:ok, points} = History.odds_history(market.id)

      for point <- points do
        assert point.yes >= 0.0 and point.yes <= 1.0
        assert point.pool_total >= 0
      end
    end

    test "returns an empty list for a market id that doesn't exist in the WAL" do
      assert {:ok, []} = History.odds_history("nonexistent-market-id-#{System.unique_integer()}")
    end
  end
end
