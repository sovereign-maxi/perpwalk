defmodule PerpWalk.Markets.AMMTest do
  @moduledoc "Unit tests for PerpWalk.Markets.AMM."

  use ExUnit.Case, async: true

  alias PerpWalk.Markets.AMM

  describe "new/2" do
    test "creates a pool with positive YES and NO reserves" do
      pool = AMM.new(100, 100)
      assert %AMM{yes: 100, no: 100} = pool
    end

    test "asymmetric reserves are allowed" do
      pool = AMM.new(50, 200)
      assert pool.yes == 50
      assert pool.no == 200
    end

    test "rejects zero or negative reserves" do
      assert_raise FunctionClauseError, fn -> AMM.new(0, 100) end
      assert_raise FunctionClauseError, fn -> AMM.new(100, 0) end
      assert_raise FunctionClauseError, fn -> AMM.new(-1, 100) end
    end
  end

  describe "invariant/1" do
    test "returns YES × NO" do
      assert AMM.invariant(AMM.new(100, 100)) == 10_000
      assert AMM.invariant(AMM.new(50, 200)) == 10_000
      assert AMM.invariant(AMM.new(7, 13)) == 91
    end
  end

  describe "mid_probability/2" do
    test "returns 50/50 for a symmetric pool" do
      pool = AMM.new(100, 100)
      assert AMM.mid_probability(pool, :yes) == {100, 200}
      assert AMM.mid_probability(pool, :no) == {100, 200}
    end

    test "returns NO_reserve / total for YES" do
      pool = AMM.new(40, 60)
      assert AMM.mid_probability(pool, :yes) == {60, 100}
    end

    test "returns YES_reserve / total for NO" do
      pool = AMM.new(40, 60)
      assert AMM.mid_probability(pool, :no) == {40, 100}
    end

    test "the two probabilities sum to 1 for any pool" do
      for {y, n} <- [{50, 50}, {1, 99}, {99, 1}, {137, 421}] do
        pool = AMM.new(y, n)
        {ny, dy} = AMM.mid_probability(pool, :yes)
        {nn, dn} = AMM.mid_probability(pool, :no)
        # Same denominator, numerators sum to denominator.
        assert dy == dn
        assert ny + nn == dy
      end
    end
  end

  describe "quote/3 — buying YES" do
    test "returns insufficient_liquidity when buying the entire YES side" do
      pool = AMM.new(100, 100)
      assert AMM.quote(pool, :yes, 100) == {:error, :insufficient_liquidity}
    end

    test "returns insufficient_liquidity when buying more than the YES side" do
      pool = AMM.new(100, 100)
      assert AMM.quote(pool, :yes, 200) == {:error, :insufficient_liquidity}
    end

    test "drops YES reserve by less than `contracts` and grows NO reserve" do
      # FPMM collateral-splitting: the user's collateral mints YES
      # back into the pool, so the bought-side reserve drops by
      # `contracts - amm_cost`, not by the full `contracts`. The
      # opposite-side reserve grows by `amm_cost`.
      pool = AMM.new(100, 100)
      {:ok, _cost, new_pool} = AMM.quote(pool, :yes, 10)

      assert new_pool.yes < 100
      assert new_pool.yes > 90
      assert new_pool.no > 100
    end

    test "preserves the constant-product invariant (non-decreasing)" do
      # Operator-favouring rounding (ceil sqrt + ceil div) means K can
      # only grow, never shrink. The upper bound is loose — a single
      # trade can inflate K by up to roughly the sum of the new reserves
      # (worst case of two independent ceiling roundings).
      pool = AMM.new(100, 100)
      k = AMM.invariant(pool)

      {:ok, _cost, new_pool} = AMM.quote(pool, :yes, 10)
      new_k = AMM.invariant(new_pool)

      assert new_k >= k
      assert new_k <= k + new_pool.yes + new_pool.no
    end

    test "cost reflects FPMM pricing with 1.5% spread on top" do
      # FPMM cost for buying 1 YES from (100, 100):
      #   b = 100 + 100 - 1 = 199
      #   D = 199² + 4·1·100 = 40001
      #   isqrt_ceil(40001) = 201 (since 200² = 40000 < 40001)
      #   amm_cost = ceil((201 - 199) / 2) = 1
      # With 1.5% spread: 1 + ceil(1 * 15000 / 1000000) = 1 + 1 = 2.
      pool = AMM.new(100, 100)
      {:ok, cost, _new_pool} = AMM.quote(pool, :yes, 1)
      assert cost == 2
    end
  end

  describe "quote/3 — buying NO" do
    test "returns insufficient_liquidity when buying the entire NO side" do
      pool = AMM.new(100, 100)
      assert AMM.quote(pool, :no, 100) == {:error, :insufficient_liquidity}
    end

    test "drops NO reserve by less than `contracts` and grows YES reserve" do
      pool = AMM.new(100, 100)
      {:ok, _cost, new_pool} = AMM.quote(pool, :no, 10)

      assert new_pool.no < 100
      assert new_pool.no > 90
      assert new_pool.yes > 100
    end

    test "preserves the constant-product invariant (non-decreasing)" do
      pool = AMM.new(100, 100)
      k = AMM.invariant(pool)

      {:ok, _cost, new_pool} = AMM.quote(pool, :no, 10)
      new_k = AMM.invariant(new_pool)

      assert new_k >= k
      assert new_k <= k + new_pool.yes + new_pool.no
    end
  end

  describe "quote/3 — symmetry" do
    test "buying YES and buying NO from a symmetric pool give equal costs" do
      pool = AMM.new(1000, 1000)
      {:ok, yes_cost, _} = AMM.quote(pool, :yes, 5)
      {:ok, no_cost, _} = AMM.quote(pool, :no, 5)
      assert yes_cost == no_cost
    end

    test "buying drives the price up (next quote costs more)" do
      pool = AMM.new(1000, 1000)
      {:ok, c1, after_first} = AMM.quote(pool, :yes, 1)
      {:ok, c2, _} = AMM.quote(after_first, :yes, 1)

      assert c2 >= c1
    end
  end

  describe "quote/3 — input validation" do
    test "rejects non-positive contract counts with :invalid_contracts" do
      pool = AMM.new(100, 100)

      assert {:error, :invalid_contracts} = AMM.quote(pool, :yes, 0)
      assert {:error, :invalid_contracts} = AMM.quote(pool, :yes, -1)
      assert {:error, :invalid_contracts} = AMM.quote(pool, :no, 0)
    end

    test "rejects non-integer contract counts with :invalid_contracts" do
      pool = AMM.new(100, 100)

      assert {:error, :invalid_contracts} = AMM.quote(pool, :yes, 1.5)
      assert {:error, :invalid_contracts} = AMM.quote(pool, :yes, "10")
    end
  end

  describe "quote_breakdown/3" do
    test "amm_cost + spread sums to cost" do
      pool = AMM.new(1000, 1000)

      {:ok, %{cost: cost, amm_cost: amm_cost, spread: spread, pool: _}} =
        AMM.quote_breakdown(pool, :yes, 100)

      assert cost == amm_cost + spread
      assert amm_cost > 0
      assert spread > 0
      assert spread == ceil_div(amm_cost * 15_000, 1_000_000)
    end

    test "cost matches legacy quote/3 cost (no behavior change for existing callers)" do
      pool = AMM.new(500, 1500)
      {:ok, cost_legacy, _} = AMM.quote(pool, :no, 50)
      {:ok, %{cost: cost_breakdown}} = AMM.quote_breakdown(pool, :no, 50)
      assert cost_legacy == cost_breakdown
    end

    test "returns insufficient_liquidity on the same boundary as quote/3" do
      pool = AMM.new(10, 100)
      assert {:error, :insufficient_liquidity} = AMM.quote_breakdown(pool, :yes, 10)
      assert {:error, :insufficient_liquidity} = AMM.quote_breakdown(pool, :yes, 11)
    end
  end

  describe "subunit-aware user-level pricing (regression net)" do
    # Regression net for the integer-rounding bug that priced a
    # 1-contract YES at 50/50 odds on a 100-contract-depth pool at
    # 2 × unit_size (200% of fair). The fix scales the pool 1000× so
    # the quadratic cost rounds at 0.001-contract precision rather
    # than whole-contract precision; user-level pricing now matches
    # marginal probability within the documented 1.5% spread.

    @unit_size 10_000_000_000

    test "1-contract YES at 50/50 odds prices near fair (not 2× payout)" do
      # 100 contracts of depth, scaled to subunits for the AMM.
      pool = AMM.new(AMM.to_subunits(100), AMM.to_subunits(100))
      contracts_subunits = AMM.to_subunits(1)

      {:ok, cost_subunits, _} = AMM.quote(pool, :yes, contracts_subunits)
      cost_piconeros = AMM.cost_to_piconeros(cost_subunits, @unit_size)

      # 50/50 fair price + 1.5% spread ≈ 0.5075 × unit_size.
      # Allow generous slack for ceiling rounding on small reserves.
      lower_bound = div(@unit_size * 50, 100)
      upper_bound = div(@unit_size * 53, 100)
      assert cost_piconeros >= lower_bound
      assert cost_piconeros <= upper_bound
    end

    test "cost_to_piconeros always returns at most contracts × unit_size (max payout invariant)" do
      # Sanity invariant: you can never pay more than the max possible
      # payout — that would be negative expected value at any odds.
      # Sweep multiple pool depths and contract sizes.
      for depth_contracts <- [10, 100, 1000, 10_000],
          contracts <- [1, 5, 50] do
        pool = AMM.new(AMM.to_subunits(depth_contracts), AMM.to_subunits(depth_contracts))
        max_payout = contracts * @unit_size

        if contracts < depth_contracts do
          {:ok, cost_subunits, _} = AMM.quote(pool, :yes, AMM.to_subunits(contracts))
          cost_piconeros = AMM.cost_to_piconeros(cost_subunits, @unit_size)

          assert cost_piconeros <= max_payout,
                 "cost #{cost_piconeros} exceeds max payout #{max_payout} for " <>
                   "#{contracts}@#{depth_contracts}-depth"
        end
      end
    end

    test "buying YES + buying NO costs sum to ~100-103% of total payout" do
      # At any pool depth, buying N YES + N NO should cost roughly N
      # collateral units plus a 1.5% spread on each leg (per-trade
      # spread applied twice).
      pool = AMM.new(AMM.to_subunits(1000), AMM.to_subunits(1000))
      contracts_subunits = AMM.to_subunits(10)

      {:ok, yes_cost, _} = AMM.quote(pool, :yes, contracts_subunits)
      {:ok, no_cost, _} = AMM.quote(pool, :no, contracts_subunits)

      yes_piconeros = AMM.cost_to_piconeros(yes_cost, @unit_size)
      no_piconeros = AMM.cost_to_piconeros(no_cost, @unit_size)

      total = yes_piconeros + no_piconeros
      payout = 10 * @unit_size

      # 100% (no spread, but ceiling rounding floor) to 103% (full
      # 3% spread). At depth 1000 the spread is very close to 3% flat.
      assert total >= payout
      assert total <= div(payout * 103, 100)
    end

    test "to_subunits and pool_scale round-trip" do
      assert AMM.to_subunits(0) == 0
      assert AMM.to_subunits(1) == AMM.pool_scale()
      assert AMM.to_subunits(100) == 100 * AMM.pool_scale()
    end

    test "cost_to_piconeros rounds up dust (operator's favour)" do
      # 1 subunit × 10_000_000_000 / 1000 = 10_000_000 piconeros (clean div).
      assert AMM.cost_to_piconeros(1, 10_000_000_000) == 10_000_000

      # 1 subunit × 1 / 1000 = 0.001 piconero → ceil-divs to 1.
      assert AMM.cost_to_piconeros(1, 1) == 1
    end
  end

  defp ceil_div(num, den) when den > 0, do: div(num + den - 1, den)
end
