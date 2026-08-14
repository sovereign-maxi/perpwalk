# Integration test
defmodule PerpWalk.Telemetry.Alerts.ManagerIntegrationTest do
  @moduledoc "Integration tests for alert-manager crash resilience."

  use PerpWalk.IntegrationCase

  alias PerpWalk.Telemetry.Alerts.Manager
  alias PerpWalk.Telemetry.Alerts.Rule

  test "a rule condition that exits cannot kill the manager" do
    # Run an isolated Manager carrying the hostile rule. The app-
    # supervised instance owns the named rules table, so it has to
    # step aside first — terminate_child keeps the supervisor from
    # restarting it underneath the test instance. The app instance
    # comes back (with the default ruleset) on test exit.
    :ok = Supervisor.terminate_child(PerpWalk.Telemetry.Supervisor, Manager)

    on_exit(fn ->
      _ = Supervisor.restart_child(PerpWalk.Telemetry.Supervisor, Manager)
    end)

    # The condition EXITS (GenServer.call to a dead name) rather than
    # raising. A linked task propagates that exit to its caller — the
    # pre-fix evaluation path died here once per eval tick. The long
    # interval keeps the scheduled tick out of the way; evaluation is
    # driven explicitly below.
    pid =
      start_supervised!(
        {Manager,
         rules: [
           %Rule{
             name: :__exit_test__,
             domain: "Test",
             condition: fn -> GenServer.call(:no_such_process_xyz, :ping) end,
             severity: :warning
           }
         ],
         interval_ms: 60_000}
      )

    send(pid, :evaluate)
    _ = :sys.get_state(pid)

    assert Process.alive?(pid)
    assert Enum.any?(Manager.all_rules(), &(&1.name == :__exit_test__))
  end
end
