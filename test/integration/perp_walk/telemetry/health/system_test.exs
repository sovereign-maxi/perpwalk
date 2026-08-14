defmodule PerpWalk.Telemetry.Health.SystemIntegrationTest do
  @moduledoc """
  Integration tests for the auto-halt persistent_term write/erase logic in
  `PerpWalk.Telemetry.Health.System`. Calls `sync_auto_halt/1`
  directly with synthesised alert lists rather than spinning up the
  GenServer; the GenServer wiring is exercised by integration tests.
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Telemetry.Alerts.Rule
  alias PerpWalk.Telemetry.Health.System, as: HealthSystem

  @auto_key {HealthSystem, :auto_halt}
  @manual_key {HealthSystem, :manual_halt}

  setup do
    on_exit(fn ->
      :persistent_term.erase(@auto_key)
      :persistent_term.erase(@manual_key)
    end)

    :ok
  end

  defp rule(name, severity \\ :critical) do
    %Rule{
      name: name,
      domain: "Test",
      condition: fn -> :ok end,
      severity: severity
    }
  end

  describe "sync_auto_halt/1" do
    test "leaves persistent_term unset when no halt-class alerts are active" do
      HealthSystem.sync_auto_halt([rule(:tor_degraded, :warning)])

      assert :persistent_term.get(@auto_key, nil) == nil
    end

    test "writes persistent_term when a halt-class alert is active" do
      HealthSystem.sync_auto_halt([rule(:federation_quorum_lost)])

      assert {true, reason} = :persistent_term.get(@auto_key, nil)
      assert reason =~ "federation_quorum_lost"
    end

    test "writes persistent_term for each disk-halt alert" do
      for halt_alert <- [
            :disk_usage_critical_root,
            :disk_usage_critical_data,
            :data_volume_unmounted
          ] do
        :persistent_term.erase(@auto_key)

        HealthSystem.sync_auto_halt([rule(halt_alert)])

        assert {true, reason} = :persistent_term.get(@auto_key, nil)
        assert reason =~ Atom.to_string(halt_alert)
      end
    end

    test "erases persistent_term when alerts clear" do
      :persistent_term.put(@auto_key, {true, "stale halt"})

      HealthSystem.sync_auto_halt([])

      assert :persistent_term.get(@auto_key, nil) == nil
    end

    test "leaves a manual halt untouched when sync_auto_halt runs" do
      :persistent_term.put(@manual_key, {true, "operator halt"})

      HealthSystem.sync_auto_halt([])

      assert {true, "operator halt"} = :persistent_term.get(@manual_key, nil)
    end

    test "includes every triggering alert name in the reason string" do
      HealthSystem.sync_auto_halt([
        rule(:federation_quorum_lost),
        rule(:disk_usage_critical_data)
      ])

      assert {true, reason} = :persistent_term.get(@auto_key, nil)
      assert reason =~ "federation_quorum_lost"
      assert reason =~ "disk_usage_critical_data"
    end
  end

  describe "halted?/0 and halt_reason/0" do
    test "halted? is false when no halt is set" do
      refute HealthSystem.halted?()
      assert HealthSystem.halt_reason() == nil
    end

    test "manual halt is observable via halted?/0 and halt_reason/0" do
      HealthSystem.set_halted("rotating signers")

      assert HealthSystem.halted?()
      assert HealthSystem.halt_reason() == "rotating signers"
    end

    test "manual halt reason takes precedence over auto halt reason" do
      :persistent_term.put(@auto_key, {true, "auto reason"})
      :persistent_term.put(@manual_key, {true, "manual reason"})

      assert HealthSystem.halt_reason() == "manual reason"
    end

    test "clear_halt/0 clears only manual halt, not auto halt" do
      :persistent_term.put(@auto_key, {true, "auto reason"})
      HealthSystem.set_halted("manual reason")

      HealthSystem.clear_halt()

      assert HealthSystem.halted?()
      assert HealthSystem.halt_reason() == "auto reason"
    end
  end

  describe "boot-owned halt registry" do
    test "source-halts table is created at application boot, not lazily by a caller" do
      assert :ets.whereis(:perpwalk_health_source_halts) != :undefined

      HealthSystem.set_source_halt(:test_boot_source, "test")
      assert HealthSystem.source_halts()[:test_boot_source] == "test"
      HealthSystem.clear_source_halt(:test_boot_source)
      refute Map.has_key?(HealthSystem.source_halts(), :test_boot_source)
    end
  end
end
