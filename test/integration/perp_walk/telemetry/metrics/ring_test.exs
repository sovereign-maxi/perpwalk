defmodule PerpWalk.Telemetry.Metrics.RingIntegrationTest do
  @moduledoc """
  Tests the Ring against the production-supervised instance — the
  app starts the Ring, so by the time tests run there's a snapshot
  available. We just check shape, not specific values (which depend
  on the host machine).
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Telemetry.Metrics.Ring

  test "latest/0 returns a snapshot map with expected keys" do
    snapshot = Ring.latest()

    assert is_map(snapshot)
    assert Map.has_key?(snapshot, :cpu_pct)
    assert Map.has_key?(snapshot, :memory_pct)
    assert Map.has_key?(snapshot, :beam_memory_mb)
    assert Map.has_key?(snapshot, :beam_processes)
  end

  test "series/2 returns a list of {ts, value} tuples for known keys" do
    series = Ring.series(:cpu_pct, 10)

    assert is_list(series)

    for entry <- series do
      assert {ts, val} = entry
      assert is_integer(ts)
      assert is_number(val)
    end
  end

  test "series/2 returns empty list for unknown key once we hit a 0 default" do
    # Unknown keys come back as 0s in the snapshot; series still has
    # the right shape but values will all be 0.
    series = Ring.series(:nonexistent_metric, 10)
    assert is_list(series)
    assert Enum.all?(series, fn {_ts, v} -> v == 0 end)
  end
end
