defmodule PerpWalk.Scenarios.ReplicationObservabilityTest do
  @moduledoc """
  Scenario: replication-observability wiring end-to-end. Asserts the
  per-peer telemetry events emitted by `Storage.Replicator`, their
  population in `Telemetry.Health.Cache`, and the alert rules
  consuming them all agree across the chain.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  alias PerpWalk.Telemetry.Health.Cache

  # The check functions are private — invoke them through the public
  # rule list, which gives us a clean integration shape and avoids
  # touching internals.
  alias PerpWalk.Telemetry.Alerts.Manager
  alias PerpWalk.Telemetry.Alerts.Rule

  setup do
    # Cache lives in the application; ensure replicator entries are
    # cleared between tests so threshold checks see a known state.
    on_exit(fn ->
      Cache.clear_replicator_ticks()
      Cache.clear(:replication_batch_rejected)
    end)

    :ok
  end

  describe "Cache subscription to replicator telemetry" do
    test "per-peer :replicator_tick is populated from the tick telemetry event" do
      :telemetry.execute(
        [:perp_walk, :storage, :replicator, :tick],
        %{cursor: 42, peer_tip: 100, lag: 58, batch_size: 17},
        %{peer: :p2, result: :ok}
      )

      cached = Cache.get({:replicator_tick, :p2})
      assert cached.cursor == 42
      assert cached.peer_tip == 100
      assert cached.lag == 58
      assert cached.batch_size == 17
      assert cached.result == :ok
      assert %DateTime{} = cached.timestamp
    end

    test "max_lag/0 returns the largest lag observed across all peers" do
      :telemetry.execute(
        [:perp_walk, :storage, :replicator, :tick],
        %{cursor: 100, peer_tip: 200, lag: 100, batch_size: 0},
        %{peer: :p2, result: :ok}
      )

      :telemetry.execute(
        [:perp_walk, :storage, :replicator, :tick],
        %{cursor: 50, peer_tip: 800, lag: 750, batch_size: 0},
        %{peer: :p3, result: :ok}
      )

      assert Cache.max_lag() == 750
    end

    test ":replication_batch_rejected is populated from the rejection event" do
      :telemetry.execute(
        [:perp_walk, :storage, :replicator, :batch_rejected],
        %{count: 5},
        %{reason: {:seq_regression, :market_put, 50, 49}}
      )

      cached = Cache.get(:replication_batch_rejected)
      assert cached.count == 5
      assert cached.reason == {:seq_regression, :market_put, 50, 49}
      assert %DateTime{} = cached.timestamp
    end
  end

  describe "alert rules" do
    defp condition_for(rule_name) do
      rule = Enum.find(Manager.all_rules(), fn %Rule{name: n} -> n == rule_name end)
      refute is_nil(rule), "expected rule #{rule_name} to be registered"
      rule.condition
    end

    test ":peer_replication_lagging is :ok when no tick recorded" do
      assert condition_for(:peer_replication_lagging).() == :ok
    end

    test ":peer_replication_lagging is :ok when lag is under the warning threshold" do
      :telemetry.execute(
        [:perp_walk, :storage, :replicator, :tick],
        %{cursor: 100, peer_tip: 200, lag: 100, batch_size: 0},
        %{peer: :p2, result: :ok}
      )

      assert condition_for(:peer_replication_lagging).() == :ok
    end

    test ":peer_replication_lagging fires when lag is over the warning threshold" do
      :telemetry.execute(
        [:perp_walk, :storage, :replicator, :tick],
        %{cursor: 100, peer_tip: 5_000, lag: 4_900, batch_size: 1_000},
        %{peer: :p2, result: :ok}
      )

      assert {:alert, msg} = condition_for(:peer_replication_lagging).()
      assert msg =~ "lag=4900"
      assert msg =~ "threshold=500"
    end

    test ":peer_replication_lagging_critical only fires at the higher threshold" do
      :telemetry.execute(
        [:perp_walk, :storage, :replicator, :tick],
        %{cursor: 100, peer_tip: 1_500, lag: 1_400, batch_size: 1_000},
        %{peer: :p2, result: :ok}
      )

      assert {:alert, _} = condition_for(:peer_replication_lagging).()
      assert condition_for(:peer_replication_lagging_critical).() == :ok
    end

    test ":peer_replication_lagging_critical fires past 5000" do
      :telemetry.execute(
        [:perp_walk, :storage, :replicator, :tick],
        %{cursor: 100, peer_tip: 7_000, lag: 6_900, batch_size: 1_000},
        %{peer: :p2, result: :ok}
      )

      assert {:alert, msg} = condition_for(:peer_replication_lagging_critical).()
      assert msg =~ "lag=6900"
      assert msg =~ "threshold=5000"
    end

    test "lag check uses the max across peers" do
      # p2 is fine, p3 is way behind — the critical alert fires on p3.
      :telemetry.execute(
        [:perp_walk, :storage, :replicator, :tick],
        %{cursor: 100, peer_tip: 110, lag: 10, batch_size: 0},
        %{peer: :p2, result: :ok}
      )

      :telemetry.execute(
        [:perp_walk, :storage, :replicator, :tick],
        %{cursor: 100, peer_tip: 7_000, lag: 6_900, batch_size: 1_000},
        %{peer: :p3, result: :ok}
      )

      assert {:alert, msg} = condition_for(:peer_replication_lagging_critical).()
      assert msg =~ "lag=6900"
    end

    test ":replication_batch_rejected fires immediately on a fresh rejection" do
      :telemetry.execute(
        [:perp_walk, :storage, :replicator, :batch_rejected],
        %{count: 3},
        %{reason: :seq_regression}
      )

      assert {:alert, msg} = condition_for(:replication_batch_rejected).()
      assert msg =~ "reason=:seq_regression"
    end

    test ":replication_batch_rejected resolves once the rejection ages out" do
      # Inject a stale rejection (>60s old).
      stale_ts = DateTime.add(DateTime.utc_now(), -120, :second)

      :ets.insert(
        Cache,
        {:replication_batch_rejected, %{count: 1, reason: :seq_regression, timestamp: stale_ts}}
      )

      assert condition_for(:replication_batch_rejected).() == :ok
    end

    test ":replication_batch_rejected is :ok when no rejection has been recorded" do
      assert condition_for(:replication_batch_rejected).() == :ok
    end
  end
end
