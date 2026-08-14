defmodule PerpWalk.Markets.VoteTest do
  @moduledoc "Unit tests for PerpWalk.Markets.Vote."

  use ExUnit.Case, async: true

  alias PerpWalk.Markets.Vote

  describe "new/3" do
    test "creates an up-vote" do
      v = Vote.new("acct123", "mkt456", :up)
      assert v.account_id == "acct123"
      assert v.market_id == "mkt456"
      assert v.direction == :up
      assert %DateTime{} = v.created_at
    end

    test "creates a down-vote" do
      v = Vote.new("acct", "mkt", :down)
      assert v.direction == :down
    end

    test "rejects invalid directions" do
      assert_raise FunctionClauseError, fn -> Vote.new("a", "m", :neutral) end
      assert_raise FunctionClauseError, fn -> Vote.new("a", "m", :sideways) end
    end

    test "rejects non-binary IDs" do
      assert_raise FunctionClauseError, fn -> Vote.new(:atom_id, "mkt", :up) end
      assert_raise FunctionClauseError, fn -> Vote.new("acct", 42, :up) end
    end
  end
end
