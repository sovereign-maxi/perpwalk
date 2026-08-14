defmodule PerpWalk.Sim.MetricsTest do
  @moduledoc "Unit tests for the sim metrics counter store."

  use ExUnit.Case, async: false

  alias PerpWalk.Sim.Metrics

  setup do
    Metrics.reset()
    :ok
  end

  test "incr/1 increments by 1 by default" do
    Metrics.incr(:test_counter)
    Metrics.incr(:test_counter)
    Metrics.incr(:test_counter)

    assert Metrics.get(:test_counter) == 3
  end

  test "incr/2 supports custom increments" do
    Metrics.incr(:by_n, 5)
    Metrics.incr(:by_n, 10)

    assert Metrics.get(:by_n) == 15
  end

  test "tuple keys work as namespaced metrics" do
    Metrics.incr({:vote, :up})
    Metrics.incr({:vote, :up})
    Metrics.incr({:vote, :down})

    assert Metrics.get({:vote, :up}) == 2
    assert Metrics.get({:vote, :down}) == 1
  end

  test "get/1 returns 0 for unknown metrics" do
    assert Metrics.get(:never_set) == 0
  end

  test "snapshot/0 returns the full counter map" do
    Metrics.incr(:a, 10)
    Metrics.incr(:b, 20)

    snap = Metrics.snapshot()

    assert snap[:a] == 10
    assert snap[:b] == 20
  end

  test "reset/0 clears all counters" do
    Metrics.incr(:before, 5)
    Metrics.reset()

    assert Metrics.get(:before) == 0
    assert Metrics.snapshot() == %{}
  end

  test "concurrent incr from many processes is atomic" do
    parent = self()

    tasks =
      for _ <- 1..100 do
        Task.async(fn ->
          Enum.each(1..10, fn _ -> Metrics.incr(:concurrent) end)
          send(parent, :done)
        end)
      end

    Enum.each(tasks, &Task.await(&1, 5_000))

    assert Metrics.get(:concurrent) == 1_000
  end
end
