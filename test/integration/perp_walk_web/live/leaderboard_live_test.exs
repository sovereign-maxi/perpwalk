defmodule PerpWalkWeb.LeaderboardLiveIntegrationTest do
  @moduledoc "Integration tests for the standalone /leaderboard route."

  use PerpWalkWeb.IntegrationCase

  alias PerpWalk.Markets.Services.{Resolver, Trader}

  describe "GET /leaderboard" do
    test "renders the empty state when no settled markets exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/leaderboard")

      assert html =~ "LEADERBOARD"
      assert html =~ "NO RANKINGS YET"
    end

    test "ranks an account once it crosses the min_resolved threshold", %{conn: conn} do
      # Three settled wins clears the LiveView's min_resolved=3 floor.
      Enum.each(1..3, fn _ ->
        market = pending_market!([]) |> activate!()
        {:ok, _} = Trader.place_position("acct-rank", market.id, :yes, 1)
        {:ok, _} = Resolver.expire(market.id)
        {:ok, _} = Resolver.submit_resolution(market.id, :yes)
        {:ok, _} = Resolver.settle(market.id)
      end)

      {:ok, _view, html} = live(conn, "/leaderboard")

      assert html =~ "LEADERBOARD"
      refute html =~ "NO RANKINGS YET"
      # 3 resolved / 3 wins / 0 losses / 100%
      assert html =~ "100%"
      assert html =~ ~s(class="bp-cell-num">3)
      assert html =~ ~s(class="bp-cell-num">0)
    end
  end
end
