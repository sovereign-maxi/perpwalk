defmodule PerpWalk.Telemetry.Alerts.RuleTest do
  @moduledoc "Unit tests for PerpWalk.Telemetry.Alerts.Rule transitions."

  use ExUnit.Case, async: true

  alias PerpWalk.Telemetry.Alerts.Rule

  describe "evaluate/1 — basic transitions" do
    test "ok stays ok when condition returns :ok" do
      rule = build_rule(condition: fn -> :ok end)
      result = Rule.evaluate(rule)

      assert result.state == :ok
    end

    test "ok → firing when condition returns alert and for_duration is 0" do
      rule = build_rule(condition: fn -> {:alert, "boom"} end, for_duration: 0)
      result = Rule.evaluate(rule)

      assert result.state == :firing
      assert result.reason == "boom"
      assert %DateTime{} = result.fired_at
    end

    test "ok → pending when condition returns alert and for_duration > 0" do
      rule = build_rule(condition: fn -> {:alert, "boom"} end, for_duration: 30_000)
      result = Rule.evaluate(rule)

      assert result.state == :pending
      assert result.reason == "boom"
      assert is_integer(result.pending_since)
    end

    test "pending stays pending while inside debounce window" do
      rule = %{
        build_rule(condition: fn -> {:alert, "still bad"} end, for_duration: 30_000)
        | state: :pending,
          pending_since: System.monotonic_time(:millisecond),
          reason: "old reason"
      }

      result = Rule.evaluate(rule)

      assert result.state == :pending
      assert result.reason == "still bad"
    end

    test "pending → ok when condition clears before debounce" do
      rule = %{
        build_rule(condition: fn -> :ok end, for_duration: 30_000)
        | state: :pending,
          pending_since: System.monotonic_time(:millisecond),
          reason: "transient"
      }

      result = Rule.evaluate(rule)

      assert result.state == :ok
      assert result.reason == nil
    end
  end

  describe "evaluate/1 — resolution debouncing" do
    test "firing → resolving on first OK with resolve_after > 1" do
      rule = %{build_rule(condition: fn -> :ok end, resolve_after: 3) | state: :firing}

      result = Rule.evaluate(rule)

      assert result.state == :resolving
      assert result.ok_count == 1
    end

    test "resolving → resolved after enough consecutive OKs" do
      rule = %{
        build_rule(condition: fn -> :ok end, resolve_after: 3)
        | state: :resolving,
          ok_count: 2
      }

      result = Rule.evaluate(rule)

      assert result.state == :resolved
      assert %DateTime{} = result.resolved_at
    end

    test "resolving → firing when alert returns mid-resolution" do
      rule = %{
        build_rule(condition: fn -> {:alert, "back"} end, resolve_after: 3)
        | state: :resolving,
          ok_count: 2
      }

      result = Rule.evaluate(rule)

      assert result.state == :firing
      assert result.ok_count == 0
    end

    test "resolved → ok on next evaluation, completing the cycle" do
      rule = %{build_rule(condition: fn -> :ok end) | state: :resolved}

      result = Rule.evaluate(rule)

      assert result.state == :ok
    end
  end

  describe "firing?/1" do
    test "true for :firing and :resolving" do
      assert Rule.firing?(%{build_rule() | state: :firing})
      assert Rule.firing?(%{build_rule() | state: :resolving})
    end

    test "false for :ok, :pending, :resolved" do
      refute Rule.firing?(%{build_rule() | state: :ok})
      refute Rule.firing?(%{build_rule() | state: :pending})
      refute Rule.firing?(%{build_rule() | state: :resolved})
    end
  end

  describe "evaluate/1 — safety" do
    test "crashing condition is treated as :ok (safe-eval)" do
      rule = build_rule(condition: fn -> raise "boom" end)

      result = Rule.evaluate(rule)

      assert result.state == :ok
    end
  end

  defp build_rule(opts \\ []) do
    %Rule{
      name: Keyword.get(opts, :name, :test_rule),
      domain: Keyword.get(opts, :domain, "Test"),
      severity: Keyword.get(opts, :severity, :warning),
      condition: Keyword.get(opts, :condition, fn -> :ok end),
      for_duration: Keyword.get(opts, :for_duration, 0),
      resolve_after: Keyword.get(opts, :resolve_after, 3)
    }
  end
end
