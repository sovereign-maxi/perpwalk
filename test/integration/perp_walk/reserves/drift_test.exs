defmodule PerpWalk.Reserves.DriftIntegrationTest do
  @moduledoc "Integration tests for `PerpWalk.Reserves.Drift` — touches `:persistent_term` process state."

  use PerpWalk.IntegrationCase

  alias PerpWalk.Reserves.Drift

  setup do
    Drift.reset()
    on_exit(&Drift.reset/0)
    :ok
  end

  describe "status/0" do
    test "returns no-data default before any round has been recorded" do
      assert %{divergent_peers: [], observed_at: nil} = Drift.status()
    end

    test "returns the most recently recorded state" do
      ts = DateTime.utc_now()
      :ok = Drift.record_round([:"perpwalk@10.0.0.2"], [], ts)

      assert %{divergent_peers: [:"perpwalk@10.0.0.2"], observed_at: ^ts} = Drift.status()
    end

    test "a divergent peer stays recorded across silent rounds until it attests cleanly" do
      ts1 = DateTime.utc_now()
      :ok = Drift.record_round([:"perpwalk@10.0.0.2"], [], ts1)

      # A round the peer contributed nothing to must NOT clear it.
      ts2 = DateTime.add(ts1, 600, :second)
      :ok = Drift.record_round([], [], ts2)
      assert %{divergent_peers: [:"perpwalk@10.0.0.2"]} = Drift.status()

      # A clean attestation from that peer clears it.
      ts3 = DateTime.add(ts2, 600, :second)
      :ok = Drift.record_round([], [:"perpwalk@10.0.0.2"], ts3)

      assert %{divergent_peers: [], observed_at: ^ts3} = Drift.status()
    end
  end

  describe "record_round/1" do
    test "stores empty list as the clean state" do
      assert :ok = Drift.record_round([])
      assert %{divergent_peers: []} = Drift.status()
    end

    test "stores multiple divergent peers" do
      peers = [:"perpwalk@10.0.0.2", :"perpwalk@10.0.0.3"]
      :ok = Drift.record_round(peers)

      assert %{divergent_peers: ^peers} = Drift.status()
    end

    test "defaults observed_at to now when not provided" do
      before = DateTime.utc_now()
      :ok = Drift.record_round([:"perpwalk@10.0.0.2"])
      after_call = DateTime.utc_now()

      %{observed_at: ts} = Drift.status()

      assert DateTime.compare(ts, before) in [:gt, :eq]
      assert DateTime.compare(ts, after_call) in [:lt, :eq]
    end
  end

  describe "reset/0" do
    test "clears recorded state back to no-data defaults" do
      :ok = Drift.record_round([:"perpwalk@10.0.0.2"])
      assert %{divergent_peers: [_]} = Drift.status()

      :ok = Drift.reset()
      assert %{divergent_peers: [], observed_at: nil} = Drift.status()
    end
  end
end
