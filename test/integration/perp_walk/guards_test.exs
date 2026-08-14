defmodule PerpWalk.GuardsIntegrationTest do
  @moduledoc "Integration tests for PerpWalk.Guards."

  use PerpWalk.IntegrationCase

  alias PerpWalk.Guards
  alias PerpWalk.Guards.SystemHaltedError
  alias PerpWalk.Telemetry.Health.System, as: HealthSystem

  @manual_key {HealthSystem, :manual_halt}
  @auto_key {HealthSystem, :auto_halt}

  setup do
    on_exit(fn ->
      :persistent_term.erase(@manual_key)
      :persistent_term.erase(@auto_key)
    end)

    :ok
  end

  describe "operational?/0" do
    test "is true when neither persistent_term key is set" do
      assert Guards.operational?()
    end

    test "is false when manual halt is set" do
      :persistent_term.put(@manual_key, {true, "operator halt"})

      refute Guards.operational?()
    end

    test "is false when auto halt is set" do
      :persistent_term.put(@auto_key, {true, "quorum lost"})

      refute Guards.operational?()
    end

    test "is false when both are set" do
      :persistent_term.put(@manual_key, {true, "manual"})
      :persistent_term.put(@auto_key, {true, "auto"})

      refute Guards.operational?()
    end
  end

  describe "halted?/0" do
    test "is the inverse of operational?/0" do
      assert Guards.halted?() == not Guards.operational?()

      :persistent_term.put(@auto_key, {true, "x"})

      assert Guards.halted?() == not Guards.operational?()
    end
  end

  describe "ensure_operational!/0" do
    test "returns :ok when the system is operational" do
      assert Guards.ensure_operational!() == :ok
    end

    test "raises SystemHaltedError with the manual halt reason" do
      :persistent_term.put(@manual_key, {true, "rotating signers"})

      assert_raise SystemHaltedError, ~r/rotating signers/, fn ->
        Guards.ensure_operational!()
      end
    end

    test "raises SystemHaltedError with the auto halt reason" do
      :persistent_term.put(@auto_key, {true, "halt-class alerts active: federation_quorum_lost"})

      assert_raise SystemHaltedError, ~r/federation_quorum_lost/, fn ->
        Guards.ensure_operational!()
      end
    end

    test "manual halt reason wins when both are set" do
      :persistent_term.put(@manual_key, {true, "manual reason"})
      :persistent_term.put(@auto_key, {true, "auto reason"})

      assert_raise SystemHaltedError, ~r/manual reason/, fn ->
        Guards.ensure_operational!()
      end
    end
  end
end
