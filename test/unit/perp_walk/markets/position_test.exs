defmodule PerpWalk.Markets.PositionTest do
  @moduledoc "Unit tests for PerpWalk.Markets.Position."

  use ExUnit.Case, async: true

  alias PerpWalk.Markets.Position

  describe "new/5" do
    test "opens a YES position" do
      pos = Position.new("mkt1", "acct1", :yes, 10, 53)
      assert pos.market_id == "mkt1"
      assert pos.account_id == "acct1"
      assert pos.side == :yes
      assert pos.contracts == 10
      assert pos.amount_paid == 53
      assert pos.status == :open
      assert %DateTime{} = pos.created_at
      assert pos.settled_at == nil
      assert is_binary(pos.id) and byte_size(pos.id) == 32
    end

    test "opens a NO position" do
      pos = Position.new("mkt1", "acct1", :no, 5, 30)
      assert pos.side == :no
      assert pos.status == :open
    end

    test "every position gets a unique id" do
      a = Position.new("m", "a", :yes, 1, 1)
      b = Position.new("m", "a", :yes, 1, 1)
      assert a.id != b.id
    end

    test "rejects invalid sides" do
      assert_raise FunctionClauseError, fn -> Position.new("m", "a", :maybe, 1, 1) end
    end

    test "rejects non-positive contracts or amount_paid" do
      assert_raise FunctionClauseError, fn -> Position.new("m", "a", :yes, 0, 1) end
      assert_raise FunctionClauseError, fn -> Position.new("m", "a", :yes, 1, 0) end
      assert_raise FunctionClauseError, fn -> Position.new("m", "a", :yes, -1, 1) end
    end
  end

  describe "settle/2" do
    test "marks a YES position as winner when YES outcome" do
      pos = Position.new("m", "a", :yes, 10, 50)
      {:ok, settled} = Position.settle(pos, :yes)
      assert settled.status == :settled_winner
      assert %DateTime{} = settled.settled_at
    end

    test "marks a YES position as loser when NO outcome" do
      pos = Position.new("m", "a", :yes, 10, 50)
      {:ok, settled} = Position.settle(pos, :no)
      assert settled.status == :settled_loser
    end

    test "marks a NO position as winner when NO outcome" do
      pos = Position.new("m", "a", :no, 10, 50)
      {:ok, settled} = Position.settle(pos, :no)
      assert settled.status == :settled_winner
    end

    test "marks a NO position as loser when YES outcome" do
      pos = Position.new("m", "a", :no, 10, 50)
      {:ok, settled} = Position.settle(pos, :yes)
      assert settled.status == :settled_loser
    end

    test "rejects settlement on a non-open position" do
      pos = Position.new("m", "a", :yes, 10, 50)
      {:ok, settled} = Position.settle(pos, :yes)
      assert Position.settle(settled, :yes) == {:error, :invalid_transition}
    end
  end

  describe "refund/1" do
    test "marks an open position as refunded" do
      pos = Position.new("m", "a", :yes, 10, 50)
      {:ok, refunded} = Position.refund(pos)
      assert refunded.status == :refunded
      assert %DateTime{} = refunded.settled_at
    end

    test "rejects refund on a non-open position" do
      pos = Position.new("m", "a", :yes, 10, 50)
      {:ok, settled} = Position.settle(pos, :yes)
      assert Position.refund(settled) == {:error, :invalid_transition}
    end
  end

  describe "payout/2" do
    test "winner receives contracts × unit_size" do
      pos = Position.new("m", "a", :yes, 10, 50)
      {:ok, settled} = Position.settle(pos, :yes)
      assert Position.payout(settled, 100) == 1000
    end

    test "loser receives nothing" do
      pos = Position.new("m", "a", :yes, 10, 50)
      {:ok, settled} = Position.settle(pos, :no)
      assert Position.payout(settled, 100) == 0
    end

    test "refunded position returns the amount paid" do
      pos = Position.new("m", "a", :yes, 10, 50)
      {:ok, refunded} = Position.refund(pos)
      assert Position.payout(refunded, 100) == 50
    end

    test "open position returns zero (not yet settled)" do
      pos = Position.new("m", "a", :yes, 10, 50)
      assert Position.payout(pos, 100) == 0
    end
  end
end
