defmodule PerpWalk.Scenarios.PoolCasTest do
  @moduledoc """
  Pins the compare-and-swap invariant on trade + fill writes.

  Pre-fix behaviour: `put_trade/put_fill` blindly overwrote the
  market row with the caller's stale snapshot. Two concurrent
  trades against the same pool both wrote against the same
  starting pool state; the second commit erased the first's
  update but both positions persisted — claims > collateral. A
  fill landing after Scheduler expired the market reverted
  `:expired` to `:active`.

  These tests drive the exact races that used to leak collateral.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import PerpWalk.TestHelpers.CleanState, only: [clean_state: 1]

  alias PerpWalk.Markets.{AMM, Position, Store}
  alias PerpWalk.TestHelpers.MarketsHelpers

  setup :clean_state

  describe "put_trade CAS against live market state" do
    test "refuses when live pool has moved since the caller's snapshot" do
      market = MarketsHelpers.build_market()
      :ok = Store.put_market(market)

      # T1 wins the race: applies pool update to (105, 95).
      p1 = Position.new(market.id, "acct-1", :yes, 1, 10_000)
      m1 = %{market | pool: AMM.new(105, 95)}
      expected_snapshot = %{pool: market.pool, status: market.status}

      assert :ok = Store.put_trade(m1, p1, expected_snapshot)

      # T2 lost the race: computed against the ORIGINAL pool
      # (100, 100), tries to write with the same expected.
      p2 = Position.new(market.id, "acct-2", :yes, 1, 10_000)
      m2 = %{market | pool: AMM.new(105, 95)}

      assert {:error, :concurrent_modification} =
               Store.put_trade(m2, p2, expected_snapshot)
    end

    test "refuses when live status has moved (e.g. :active → :expired)" do
      market = MarketsHelpers.build_market()
      :ok = Store.put_market(market)

      # Simulate the Scheduler flipping the market to :expired.
      expired = %{market | status: :expired}
      :ok = Store.put_market(expired)

      # A fill arrives with the caller's stale :active snapshot.
      pending = Position.new(market.id, "acct-3", :yes, 1, 10_000)
      stale_expected = %{pool: market.pool, status: :active}

      updated = %{market | pool: AMM.new(105, 95)}

      assert {:error, :concurrent_modification} =
               Store.put_trade(updated, pending, stale_expected)

      # And the live market remains :expired — no clobber.
      {:ok, [{_id, live}]} = {:ok, :ets.lookup(PerpWalk.Markets.Store.Markets, market.id)}
      assert live.status == :expired
    end

    test "accepts on a matching snapshot (control)" do
      market = MarketsHelpers.build_market()
      :ok = Store.put_market(market)

      position = Position.new(market.id, "acct-4", :yes, 1, 10_000)
      updated = %{market | pool: AMM.new(105, 95)}
      expected = %{pool: market.pool, status: market.status}

      assert :ok = Store.put_trade(updated, position, expected)
    end
  end

  describe "put_fill CAS against live market state" do
    test "refuses a fill when the market has expired between fetch and write" do
      market = MarketsHelpers.build_market()
      :ok = Store.put_market(market)

      quote = MarketsHelpers.build_quote(market_id: market.id)
      :ok = Store.put_quote(quote)

      # Scheduler expires between the poller's fetch_market and its put_fill.
      expired = %{market | status: :expired}
      :ok = Store.put_market(expired)

      position = Position.new(market.id, quote.account_id, :yes, 5, 50_000_000_000)
      updated = %{market | pool: AMM.new(105, 95)}
      stale_expected = %{pool: market.pool, status: :active}

      assert {:error, :concurrent_modification} =
               Store.put_fill(updated, position, quote.id, stale_expected)

      # Quote is NOT consumed on refusal — user can retry.
      assert {:ok, _} = PerpWalk.Markets.Store.get_quote(quote.id)
    end
  end
end
