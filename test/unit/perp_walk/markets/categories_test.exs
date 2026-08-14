defmodule PerpWalk.Markets.CategoriesTest do
  @moduledoc "Unit tests for PerpWalk.Markets.Categories."

  use ExUnit.Case, async: true

  alias PerpWalk.Markets.Categories

  describe "all/0" do
    test "returns the seven canonical categories" do
      assert Categories.all() == [
               :politics,
               :crypto,
               :finance,
               :sports,
               :entertainment,
               :science_tech,
               :culture
             ]
    end

    test "categories are unique" do
      cats = Categories.all()
      assert length(cats) == length(Enum.uniq(cats))
    end

    test "all categories are atoms" do
      Enum.each(Categories.all(), fn c -> assert is_atom(c) end)
    end
  end

  describe "valid?/1" do
    test "returns true for every canonical category" do
      Enum.each(Categories.all(), fn c -> assert Categories.valid?(c) end)
    end

    test "returns false for unknown atoms" do
      refute Categories.valid?(:unknown)
      refute Categories.valid?(:Politics)
      refute Categories.valid?(:tech)
    end

    test "returns false for non-atom inputs" do
      refute Categories.valid?("politics")
      refute Categories.valid?(42)
      refute Categories.valid?(nil)
    end
  end
end
