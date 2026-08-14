defmodule PerpWalk.Sim.ReporterTest do
  @moduledoc "Unit tests for sim report normalization and JSON encoding."

  use ExUnit.Case, async: false

  alias PerpWalk.Sim.Reporter

  test "to_json! encodes maps with atom keys" do
    summary = %{
      counters: %{},
      markets: %{total: 0, by_status: %{}},
      positions: %{total: 0, by_status: %{}},
      disputes: %{total: 0, by_status: %{}},
      payouts: %{total: 0, by_status: %{}, by_kind: %{}},
      federation_ledger: %{total_piconeros: 0},
      invariants: %{passed: true, violation_count: 0, violations: []},
      run: %{seed: 42, ticks: 100}
    }

    json = Reporter.to_json!(summary)
    decoded = Jason.decode!(json)

    assert decoded["run"]["seed"] == 42
    assert decoded["invariants"]["passed"] == true
  end

  test "to_json! encodes tuple-keyed counters" do
    summary = %{
      counters: %{
        {:vote, :up} => 10,
        {:dispute, :filed} => 5
      },
      markets: %{},
      positions: %{},
      disputes: %{},
      payouts: %{},
      federation_ledger: %{},
      invariants: %{passed: true, violation_count: 0, violations: []},
      run: %{}
    }

    json = Reporter.to_json!(summary)
    decoded = Jason.decode!(json)

    assert decoded["counters"]["vote:up"] == 10
    assert decoded["counters"]["dispute:filed"] == 5
  end

  test "to_json! encodes violations containing module + map" do
    summary = %{
      counters: %{},
      markets: %{},
      positions: %{},
      disputes: %{},
      payouts: %{},
      federation_ledger: %{},
      invariants: %{
        passed: false,
        violation_count: 1,
        violations: [{PerpWalk.Sim.Invariants.Conservation, %{kind: :total_mismatch, expected: 10, actual: 9}}]
      },
      run: %{}
    }

    json = Reporter.to_json!(summary)
    decoded = Jason.decode!(json)

    assert decoded["invariants"]["passed"] == false
    [violation] = decoded["invariants"]["violations"]
    assert is_list(violation)
    assert hd(violation) =~ "Conservation"
  end

  test "to_json! handles structs by converting to map" do
    payout = %PerpWalk.Federation.Payout{
      id: "p1",
      market_id: "m1",
      account_id: "a1",
      kind: :winner_payout,
      amount_piconeros: 1000,
      destination: "d",
      status: :pending,
      position_id: nil,
      rule_failure_reason: nil,
      payout_txid: nil,
      created_at: ~U[2026-01-01 00:00:00Z],
      updated_at: ~U[2026-01-01 00:00:00Z]
    }

    summary = %{
      counters: %{},
      markets: %{},
      positions: %{},
      disputes: %{},
      payouts: %{},
      federation_ledger: %{},
      invariants: %{
        passed: false,
        violation_count: 1,
        violations: [{Some.Invariant, %{sample: [payout]}}]
      },
      run: %{}
    }

    # Must not raise
    json = Reporter.to_json!(summary)
    decoded = Jason.decode!(json)

    [violation] = decoded["invariants"]["violations"]
    [_module, details] = violation
    [serialized_payout] = details["sample"]
    assert serialized_payout["id"] == "p1"
    assert serialized_payout["status"] == "pending"
  end
end
