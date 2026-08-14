defmodule PerpWalkWeb.Live.Components.PaginatorTest do
  @moduledoc "Unit tests for the Paginator helper functions."

  use ExUnit.Case, async: true

  alias PerpWalkWeb.Live.Components.Paginator

  describe "slice/3" do
    test "returns the right page slice" do
      rows = Enum.to_list(1..100)

      assert Paginator.slice(rows, 1, 25) == Enum.to_list(1..25)
      assert Paginator.slice(rows, 2, 25) == Enum.to_list(26..50)
      assert Paginator.slice(rows, 4, 25) == Enum.to_list(76..100)
    end

    test "last page is short when total isn't a multiple of per_page" do
      rows = Enum.to_list(1..103)
      assert Paginator.slice(rows, 5, 25) == Enum.to_list(101..103)
    end

    test "out-of-range page returns []" do
      rows = Enum.to_list(1..10)
      assert Paginator.slice(rows, 99, 25) == []
    end

    test "page=1 of an empty list is []" do
      assert Paginator.slice([], 1, 25) == []
    end
  end

  describe "clamp_page/3" do
    test "leaves a valid page untouched" do
      assert Paginator.clamp_page(2, 100, 25) == 2
      assert Paginator.clamp_page(4, 100, 25) == 4
    end

    test "clamps below 1 up to 1" do
      assert Paginator.clamp_page(0, 100, 25) == 1
      assert Paginator.clamp_page(-5, 100, 25) == 1
    end

    test "clamps above max down to max" do
      assert Paginator.clamp_page(99, 100, 25) == 4
    end

    test "an empty list clamps to page 1 (max_page is at least 1)" do
      assert Paginator.clamp_page(1, 0, 25) == 1
      assert Paginator.clamp_page(99, 0, 25) == 1
    end

    test "a partial last page is reachable" do
      # 51 rows, 25/page → 3 pages, last page has 1 row
      assert Paginator.clamp_page(3, 51, 25) == 3
      assert Paginator.clamp_page(99, 51, 25) == 3
    end
  end
end
