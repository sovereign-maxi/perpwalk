defmodule PerpWalk.Markets.LeaderboardIntegrationTest do
  @moduledoc """
  Integration tests for `PerpWalk.Markets.Leaderboard` — drives
  real Markets store transitions to verify the ranking sums and
  sort order.
  """

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers, only: [activate!: 1, pending_market!: 1]

  alias PerpWalk.Markets.Leaderboard
  alias PerpWalk.Markets.Services.{Resolver, Trader}

  defp resolve_market!(market, outcome) do
    {:ok, _} = Resolver.expire(market.id)
    {:ok, _} = Resolver.submit_resolution(market.id, outcome)
    {:ok, _} = Resolver.settle(market.id)
    :ok
  end

  defp seed_account_positions!(account_id, results) do
    # `results` is a list of {outcome_to_resolve, side_user_took}
    # tuples. The user takes `side_user_took` on a market that
    # gets resolved to `outcome_to_resolve` — when they match, the
    # account counts a win.
    Enum.each(results, fn {outcome, side} ->
      market = pending_market!([]) |> activate!()
      {:ok, _} = Trader.place_position(account_id, market.id, side, 1)
      resolve_market!(market, outcome)
    end)
  end

  describe "compute/1" do
    test "excludes accounts below the min_resolved threshold" do
      # Account with only 3 resolved markets — below default min_resolved=10.
      seed_account_positions!("acct-low", [
        {:yes, :yes},
        {:yes, :yes},
        {:no, :no}
      ])

      ranking = Leaderboard.compute(min_resolved: 10)
      refute Enum.any?(ranking, &(&1.account_id == "acct-low"))
    end

    test "includes accounts at exactly the min_resolved threshold" do
      # Five wins, no losses, threshold = 5.
      seed_account_positions!("acct-on-threshold", for(_ <- 1..5, do: {:yes, :yes}))

      ranking = Leaderboard.compute(min_resolved: 5)
      assert Enum.any?(ranking, &(&1.account_id == "acct-on-threshold"))
    end

    test "win percentage and counts are correct" do
      seed_account_positions!("acct-calibrated", [
        {:yes, :yes},
        {:yes, :yes},
        {:yes, :yes},
        {:no, :yes},
        {:no, :no}
      ])

      [entry] = Leaderboard.compute(min_resolved: 5)
      assert entry.account_id == "acct-calibrated"
      assert entry.markets_resolved == 5
      assert entry.wins == 4
      assert entry.win_pct == 80
      assert entry.rank == 1
      assert entry.handle =~ ~r/^[a-z]+-[a-z]+-\d{4}$/
      assert %DateTime{} = entry.last_active_at
    end

    test "sorts by win_pct desc, then by markets_resolved desc" do
      # alice: 5/5 = 100%
      # bob:   6/8 = 75%
      # carol: 9/9 = 100% (same pct as alice, but more resolved → ranks first)
      seed_account_positions!("acct-alice", for(_ <- 1..5, do: {:yes, :yes}))

      seed_account_positions!(
        "acct-bob",
        for(_ <- 1..6, do: {:yes, :yes}) ++ for(_ <- 1..2, do: {:yes, :no})
      )

      seed_account_positions!("acct-carol", for(_ <- 1..9, do: {:yes, :yes}))

      ranking = Leaderboard.compute(min_resolved: 5)

      account_order = Enum.map(ranking, & &1.account_id)
      assert ["acct-carol", "acct-alice", "acct-bob"] = account_order
    end

    test "excludes voided markets from both wins and totals" do
      market_voided = pending_market!([]) |> activate!()
      {:ok, _} = Trader.place_position("acct-voided", market_voided.id, :yes, 1)
      {:ok, _} = Resolver.expire(market_voided.id)
      {:ok, _} = Resolver.void(market_voided.id, :operator)

      # 5 winning settled markets to clear the threshold cleanly.
      seed_account_positions!(
        "acct-voided",
        for(_ <- 1..5, do: {:yes, :yes})
      )

      [entry] = Leaderboard.compute(min_resolved: 5)
      assert entry.account_id == "acct-voided"
      # 5 resolved (not 6 — the voided market doesn't count).
      assert entry.markets_resolved == 5
      assert entry.wins == 5
    end

    test "respects the :limit opt" do
      for i <- 1..3 do
        seed_account_positions!(
          "acct-bulk-#{i}",
          for(_ <- 1..5, do: {:yes, :yes})
        )
      end

      assert length(Leaderboard.compute(min_resolved: 5, limit: 2)) == 2
      assert length(Leaderboard.compute(min_resolved: 5, limit: 10)) == 3
    end

    test "returns empty list when no settled markets exist" do
      _ = pending_market!([]) |> activate!()
      assert Leaderboard.compute(min_resolved: 1) == []
    end
  end
end
