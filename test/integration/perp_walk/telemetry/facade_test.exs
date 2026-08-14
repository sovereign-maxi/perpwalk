defmodule PerpWalk.Telemetry.FacadeIntegrationTest do
  @moduledoc """
  Crash-safety tests for the Facade.

  The Telemetry supervision tree is started by the application — by
  the time tests run, the GenServers are alive, so the Facade should
  return real values. The point of the rescue/catch wrappers in the
  Facade is that callers don't need their own try/rescue when the
  tree happens not to be running (during recovery, shutdown, or
  isolated test contexts).
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Telemetry.Facade

  test "system_status/0 returns a known atom" do
    assert Facade.system_status() in [:healthy, :degraded, :critical, :halted]
  end

  test "health_components/0 returns a map with the expected component keys" do
    components = Facade.health_components()

    assert is_map(components)

    for key <- [:tor, :monero, :storage, :markets, :system] do
      assert Map.has_key?(components, key), "missing #{key}"
    end
  end

  test "active_alerts/0 returns a list (possibly empty)" do
    assert is_list(Facade.active_alerts())
  end

  test "system_metrics/0 returns a map (possibly empty until first tick)" do
    assert is_map(Facade.system_metrics())
  end

  test "metrics_series/2 returns a list" do
    assert is_list(Facade.metrics_series(:cpu_pct, 60))
    assert is_list(Facade.metrics_series(:nonexistent_key, 60))
  end
end
