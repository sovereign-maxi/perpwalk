defmodule PerpWalk.Markets.ModerationTest do
  @moduledoc "Unit tests for PerpWalk.Markets.Moderation."

  use ExUnit.Case, async: true

  alias PerpWalk.Markets.{Moderation, Vote}

  defp vote(direction) do
    Vote.new("acct-#{System.unique_integer([:positive])}", "mkt-1", direction)
  end

  defp downvotes(n), do: List.duplicate(vote(:down), n)
  defp upvotes(n), do: List.duplicate(vote(:up), n)

  describe "reputation/1" do
    test "returns 0 for an empty list" do
      assert Moderation.reputation([]) == 0
    end

    test "counts up votes as +1" do
      assert Moderation.reputation(upvotes(3)) == 3
    end

    test "counts down votes as -1" do
      assert Moderation.reputation(downvotes(2)) == -2
    end

    test "nets up and down votes" do
      votes = [vote(:up), vote(:down), vote(:up), vote(:down), vote(:up)]
      assert Moderation.reputation(votes) == 1
    end
  end

  describe "tally/1" do
    test "returns {0, 0} for an empty list" do
      assert Moderation.tally([]) == {0, 0}
    end

    test "counts up and down votes separately" do
      votes = [vote(:up), vote(:up), vote(:down), vote(:up), vote(:down)]
      assert Moderation.tally(votes) == {3, 2}
    end

    test "handles all-up votes" do
      assert Moderation.tally(upvotes(4)) == {4, 0}
    end

    test "handles all-down votes" do
      assert Moderation.tally(downvotes(6)) == {0, 6}
    end
  end

  describe "wilson_lower/3" do
    test "returns 0.0 for zero votes" do
      assert Moderation.wilson_lower(0, 0, 1.96) == 0.0
    end

    test "returns 0.0 for all upvotes" do
      assert Moderation.wilson_lower(0, 10, 1.96) == 0.0
    end

    test "is bounded above by p_hat" do
      # 8 down out of 10 = 0.8; lower bound must be below the point estimate.
      lb = Moderation.wilson_lower(8, 10, 1.96)
      assert lb < 0.8
      assert lb > 0.0
    end

    test "tightens (lower bound moves toward p_hat) as n grows" do
      lb_small = Moderation.wilson_lower(8, 10, 1.96)
      lb_large = Moderation.wilson_lower(80, 100, 1.96)

      # Both have the same p_hat = 0.8 but the larger sample gives
      # a tighter lower bound (closer to 0.8).
      assert lb_large > lb_small
    end

    test "unanimous downvotes at small N stay below the 0.6 cutoff" do
      # 5/5 down: lower bound ~ 0.566, below default cutoff.
      assert Moderation.wilson_lower(5, 5, 1.96) < 0.6
    end

    test "unanimous downvotes at 6/6 cross the 0.6 cutoff" do
      # 6/6 down: lower bound ~ 0.61, above default cutoff.
      assert Moderation.wilson_lower(6, 6, 1.96) >= 0.6
    end
  end

  describe "burn?/1, burn?/2" do
    test "false for an empty list" do
      refute Moderation.burn?([])
    end

    test "false below the min_votes floor regardless of unanimity" do
      # 4 unanimous downvotes — below default min_votes of 5.
      refute Moderation.burn?(downvotes(4))
    end

    test "false at 5/5 down — Wilson lower bound under 0.6" do
      refute Moderation.burn?(downvotes(5))
    end

    test "true at 6/6 down — Wilson lower bound crosses 0.6" do
      assert Moderation.burn?(downvotes(6))
    end

    test "false when a single upvote breaks unanimity at min sample" do
      votes = downvotes(5) ++ upvotes(1)
      refute Moderation.burn?(votes)
    end

    test "false for a slim majority at moderate sample" do
      # 10 down + 5 up = 67% down but Wilson lower bound ~0.42.
      votes = downvotes(10) ++ upvotes(5)
      refute Moderation.burn?(votes)
    end

    test "true for a strong majority at moderate sample" do
      # 20 down + 5 up = 80% down, Wilson lower bound ~0.61.
      votes = downvotes(20) ++ upvotes(5)
      assert Moderation.burn?(votes)
    end

    test "respects custom :lower opt" do
      # 5/5 down doesn't burn at 0.6 but does at 0.55.
      refute Moderation.burn?(downvotes(5), lower: 0.6)
      assert Moderation.burn?(downvotes(5), lower: 0.55)
    end

    test "respects custom :min_votes opt" do
      # 3/3 down: Wilson lower bound ~0.439 — below 0.6 even with
      # min_votes lifted; lower the cutoff too to confirm min_votes
      # is the gate that fires.
      refute Moderation.burn?(downvotes(3), lower: 0.4, min_votes: 5)
      assert Moderation.burn?(downvotes(3), lower: 0.4, min_votes: 3)
    end
  end

  describe "dispute_stake_for_market/1" do
    @xmr 1_000_000_000_000

    test "10% of the creator's initial liquidity, at default pct" do
      # 1 XMR seed → 0.1 XMR stake — matches the historical floor
      assert Moderation.dispute_stake_for_market(1 * @xmr) == div(@xmr, 10)
      # 10 XMR seed → 1 XMR stake
      assert Moderation.dispute_stake_for_market(10 * @xmr) == @xmr
      # 100 XMR seed (deposit max) → 10 XMR stake
      assert Moderation.dispute_stake_for_market(100 * @xmr) == 10 * @xmr
    end

    test "small deposits scale down proportionally, no floor" do
      # 0.5 XMR seed → 0.05 XMR stake (no artificial floor)
      assert Moderation.dispute_stake_for_market(div(@xmr, 2)) == div(@xmr, 20)
    end

    test "raises on zero or negative deposit" do
      assert_raise FunctionClauseError, fn -> Moderation.dispute_stake_for_market(0) end
      assert_raise FunctionClauseError, fn -> Moderation.dispute_stake_for_market(-1) end
    end
  end

  describe "default_burn_wilson_lower/0 and friends" do
    test "lower cutoff is a float in (0, 1)" do
      v = Moderation.default_burn_wilson_lower()
      assert is_float(v)
      assert v > 0.0
      assert v < 1.0
    end

    test "min_votes is a positive integer" do
      v = Moderation.default_burn_min_votes()
      assert is_integer(v)
      assert v > 0
    end

    test "z is a positive number" do
      v = Moderation.default_burn_wilson_z()
      assert is_number(v)
      assert v > 0
    end
  end
end
