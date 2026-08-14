defmodule PerpWalk.Telemetry.Alerts.Manager do
  @moduledoc """
  Periodically evaluates alert rules and publishes state transitions
  to the EventBus.

  Default rules cover system resources (CPU, memory, disk), Tor
  reachability, and the Markets resolution backlog. Each rule has a
  pure condition function that returns `:ok` or `{:alert, reason}`;
  the state machine in `Telemetry.Alerts.Rule` handles debounce and
  resolution debouncing.
  """

  use GenServer

  require Logger

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Telemetry, as: TelemetryEvents
  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Monero.Facade, as: MoneroFacade
  alias PerpWalk.Telemetry.Alerts.Rule
  alias PerpWalk.Telemetry.Health.{Cache, Metrics}

  @table __MODULE__
  @default_eval_timeout_ms 5_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Currently firing or resolving alerts."
  @spec active_alerts() :: [Rule.t()]
  def active_alerts do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, rule} -> rule end)
    |> Enum.filter(&Rule.firing?/1)
  rescue
    e ->
      Logger.warning("Manager: active_alerts failed, reason=#{inspect(e)}")
      []
  end

  @doc """
  True when the rules table is readable (Manager is up). Callers that
  derive halt state from `active_alerts/0` must check this first — the
  rescue-to-[] in `active_alerts/0` is indistinguishable from "no
  alerts firing" without it.
  """
  @spec readable?() :: boolean()
  def readable?, do: :ets.whereis(@table) != :undefined

  @doc "All rules with their current state."
  @spec all_rules() :: [Rule.t()]
  def all_rules do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, rule} -> rule end)
  rescue
    _ -> []
  end

  @doc """
  Rules whose `:resolved_at` falls within the past `window_seconds`,
  sorted newest first and capped at `limit`. Used by the admin
  events page to render a "recently resolved" strip alongside the
  active-alert column.
  """
  @spec recent_resolved(pos_integer(), pos_integer()) :: [Rule.t()]
  def recent_resolved(window_seconds \\ 86_400, limit \\ 20)
      when is_integer(window_seconds) and window_seconds > 0 and
             is_integer(limit) and limit > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -window_seconds, :second)

    all_rules()
    |> Enum.filter(fn
      %Rule{resolved_at: %DateTime{} = at} -> DateTime.compare(at, cutoff) != :lt
      _ -> false
    end)
    |> Enum.sort_by(& &1.resolved_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    table = :ets.new(@table, [:named_table, :protected, :set])
    interval = Keyword.get(opts, :interval_ms, get_config(:alert_interval_ms, 15_000))
    rules = Keyword.get(opts, :rules, default_rules())

    Enum.each(rules, fn rule -> :ets.insert(table, {rule.name, rule}) end)

    schedule_eval(interval)

    {:ok, %{table: table, interval_ms: interval}}
  end

  @impl true
  def handle_info(:evaluate, state) do
    evaluate_all_rules(state.table)
    schedule_eval(state.interval_ms)
    {:noreply, state}
  end

  # --- Private ---

  defp evaluate_all_rules(table) do
    table
    |> :ets.tab2list()
    |> Enum.each(fn {name, rule} ->
      prev_state = rule.state
      updated = evaluate_with_timeout(rule)

      :ets.insert(table, {name, updated})
      notify_transition(prev_state, updated)
    end)
  end

  defp evaluate_with_timeout(rule) do
    # async_nolink: a rule condition that EXITS (e.g. GenServer.call to
    # a restarting domain server) must not kill this Manager through the
    # task link — that crash-loops the whole alert pipeline once per
    # eval tick, silencing every alert mid-incident.
    task = Task.Supervisor.async_nolink(PerpWalk.TaskSupervisor, fn -> Rule.evaluate(rule) end)

    case Task.yield(task, eval_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        Logger.warning("Manager: rule evaluation exited, rule=#{rule.name}, reason=#{inspect(reason)}")
        rule

      nil ->
        Logger.warning("Manager: rule timed out, rule=#{rule.name}")
        rule
    end
  rescue
    e ->
      Logger.warning("Manager: rule crashed, rule=#{rule.name}, reason=#{inspect(e)}")
      rule
  end

  defp notify_transition(prev_state, %{state: :firing} = rule)
       when prev_state not in [:firing, :resolving] do
    Logger.warning("Manager: alert fired, rule=#{rule.name}, severity=#{rule.severity}, reason=#{rule.reason}")

    EventBus.publish(%TelemetryEvents.AlertFired{
      name: rule.name,
      domain: rule.domain,
      severity: rule.severity,
      reason: rule.reason,
      timestamp: DateTime.utc_now()
    })

    publish_specific_event(rule, :firing)
  end

  defp notify_transition(:resolving, %{state: :firing} = rule) do
    Logger.warning("Manager: alert re-fired, rule=#{rule.name}, severity=#{rule.severity}, reason=#{rule.reason}")

    EventBus.publish(%TelemetryEvents.AlertFired{
      name: rule.name,
      domain: rule.domain,
      severity: rule.severity,
      reason: rule.reason,
      timestamp: DateTime.utc_now()
    })
  end

  defp notify_transition(prev_state, %{state: :resolved} = rule)
       when prev_state in [:firing, :resolving] do
    Logger.info("Manager: alert resolved, rule=#{rule.name}")

    EventBus.publish(%TelemetryEvents.AlertResolved{
      name: rule.name,
      domain: rule.domain,
      detail: rule.reason,
      timestamp: DateTime.utc_now()
    })

    publish_specific_event(rule, :resolved)
  end

  defp notify_transition(_prev, _rule), do: :ok

  # Domain-specific event shadows so user-facing UI can subscribe to
  # a narrow signal without having to filter AlertFired by name.
  defp publish_specific_event(%{name: :tor_unreachable, reason: reason}, :firing) do
    EventBus.publish(%TelemetryEvents.TorDown{reason: reason, timestamp: DateTime.utc_now()})
  end

  defp publish_specific_event(%{name: :tor_unreachable}, :resolved) do
    EventBus.publish(%TelemetryEvents.TorRecovered{timestamp: DateTime.utc_now()})
  end

  defp publish_specific_event(%{name: :tor_degraded, reason: reason}, :firing) do
    EventBus.publish(%TelemetryEvents.TorDegraded{reason: reason, timestamp: DateTime.utc_now()})
  end

  defp publish_specific_event(%{name: :tor_degraded}, :resolved) do
    EventBus.publish(%TelemetryEvents.TorRecovered{timestamp: DateTime.utc_now()})
  end

  defp publish_specific_event(_rule, _transition), do: :ok

  defp schedule_eval(interval) do
    Process.send_after(self(), :evaluate, interval)
  end

  defp eval_timeout_ms do
    get_config(:alert_eval_timeout_ms, @default_eval_timeout_ms)
  end

  defp get_config(key, default) do
    Application.get_env(:perpwalk, :telemetry, [])
    |> Keyword.get(key, default)
  end

  # --- Default Rules ---

  defp default_rules do
    [
      %Rule{
        name: :resolution_backlog_high,
        domain: "Markets",
        severity: :warning,
        for_duration: 30_000,
        condition: fn -> check_resolution_backlog() end
      },
      %Rule{
        name: :cpu_high,
        domain: "System",
        severity: :warning,
        for_duration: 60_000,
        resolve_after: 3,
        condition: fn -> check_cpu(:high) end
      },
      %Rule{
        name: :cpu_critical,
        domain: "System",
        severity: :critical,
        for_duration: 30_000,
        resolve_after: 3,
        condition: fn -> check_cpu(:critical) end
      },
      %Rule{
        name: :memory_high,
        domain: "System",
        severity: :warning,
        for_duration: 60_000,
        resolve_after: 3,
        condition: fn -> check_memory(:high) end
      },
      %Rule{
        name: :memory_critical,
        domain: "System",
        severity: :critical,
        for_duration: 30_000,
        resolve_after: 3,
        condition: fn -> check_memory(:critical) end
      },
      %Rule{
        name: :tor_unreachable,
        domain: "Tor",
        severity: :critical,
        for_duration: 15_000,
        resolve_after: 3,
        condition: fn -> check_tor_reachable() end
      },
      %Rule{
        name: :tor_degraded,
        domain: "Tor",
        severity: :warning,
        for_duration: 30_000,
        resolve_after: 3,
        condition: fn -> check_tor_degraded() end
      },
      %Rule{
        name: :monero_unreachable,
        domain: "Monero",
        severity: :critical,
        for_duration: 15_000,
        resolve_after: 3,
        condition: fn -> check_monero_reachable() end
      },
      %Rule{
        name: :monero_degraded,
        domain: "Monero",
        severity: :warning,
        for_duration: 30_000,
        resolve_after: 3,
        condition: fn -> check_monero_degraded() end
      },
      %Rule{
        name: :federation_quorum_lost,
        domain: "Federation",
        severity: :critical,
        for_duration: 15_000,
        resolve_after: 3,
        condition: fn -> check_federation_quorum() end
      },
      %Rule{
        name: :federation_signing_halted,
        domain: "Federation",
        severity: :warning,
        for_duration: 0,
        resolve_after: 1,
        condition: fn -> check_federation_signing_halted() end
      },
      %Rule{
        name: :payout_awaiting_operator,
        domain: "Federation",
        severity: :critical,
        for_duration: 0,
        resolve_after: 1,
        condition: fn -> check_payout_awaiting_operator() end
      },
      %Rule{
        # Fires on the first proof cycle that detects divergent peers
        # (peers responded but disagreed on balance). Resolves only
        # after 3 consecutive clean cycles to avoid flapping. Not
        # halt-class — the federation continues operating; this is
        # a visibility signal that proof-of-reserves is silently
        # failing and the multisig sync mechanism needs to catch up.
        name: :federation_multisig_drift,
        domain: "Federation",
        severity: :critical,
        for_duration: 0,
        resolve_after: 3,
        condition: fn -> check_federation_multisig_drift() end
      },
      %Rule{
        name: :reserves_proof_stale,
        domain: "Reserves",
        severity: :warning,
        for_duration: 30_000,
        resolve_after: 3,
        condition: fn -> check_reserves_proof_stale() end
      },
      %Rule{
        name: :reserves_deficit,
        domain: "Reserves",
        severity: :critical,
        for_duration: 0,
        resolve_after: 1,
        condition: fn -> check_reserves_deficit() end
      },
      %Rule{
        name: :bootstrap_address_mismatch,
        domain: "Federation",
        severity: :emergency,
        for_duration: 0,
        resolve_after: 1,
        condition: fn -> check_bootstrap_address_mismatch() end
      },
      # Monero wallet RPC has a practical ceiling on subaddress
      # namespace before allocation latency degrades — pair the
      # high/critical levels so operators get warning before the
      # cliff.
      %Rule{
        name: :subaddress_index_high,
        domain: "Monero",
        severity: :warning,
        for_duration: 0,
        resolve_after: 1,
        condition: fn -> check_subaddress_index(:high) end
      },
      %Rule{
        name: :subaddress_index_critical,
        domain: "Monero",
        severity: :critical,
        for_duration: 0,
        resolve_after: 1,
        condition: fn -> check_subaddress_index(:critical) end
      },
      # Orphan deposits (confirmed Monero transfers landing on a
      # consumed/unknown subaddress) require operator action — funds
      # are safe in federation custody but no auto-credit happened.
      %Rule{
        name: :orphan_deposits_pending,
        domain: "Monero",
        severity: :warning,
        for_duration: 0,
        resolve_after: 1,
        condition: fn -> check_orphan_deposits() end
      },
      # Per-peer replication lag: pair of rules — warn before paging.
      # Lag spikes naturally during steady-state writes (one tick's
      # worth of unreplicated entries), so the warn threshold has
      # 30s `for_duration` to ride out transient bursts. Critical
      # severity at 5k entries / 2min means this node really isn't
      # catching up to a peer and operator attention is needed. The
      # check reads the max lag across every peer the local
      # Replicator is pulling from.
      %Rule{
        name: :peer_replication_lagging,
        domain: "Replication",
        severity: :warning,
        for_duration: 30_000,
        resolve_after: 3,
        condition: fn -> check_replication_lag(:warning) end
      },
      %Rule{
        name: :peer_replication_lagging_critical,
        domain: "Replication",
        severity: :critical,
        for_duration: 120_000,
        resolve_after: 3,
        condition: fn -> check_replication_lag(:critical) end
      },
      # Batch rejection is structural — refusing a peer's batch
      # means HMAC failure, seq regression, or WAL append error.
      # Each carries a security or correctness flag. Emergency
      # severity, no `for_duration` — fire immediately and let the
      # operator triage.
      %Rule{
        name: :replication_batch_rejected,
        domain: "Replication",
        severity: :emergency,
        for_duration: 0,
        resolve_after: 1,
        condition: fn -> check_replication_batch_rejected() end
      }
    ] ++ disk_rules()
  end

  # Per-mount disk rules are generated from `:disk_mounts` config so each
  # mount gets independently named warning/critical alerts with its own
  # thresholds — root and /data have very different "running out of room"
  # signatures. On a file-backed encrypted host, monitoring only `/` misses
  # the actual data growth entirely; monitoring only `/data` misses
  # logs/packages eating root.
  defp disk_rules do
    mounts = Application.get_env(:perpwalk, :disk_mounts, [{"/", %{high: 90, critical: 95}}])

    mount_rules =
      Enum.flat_map(mounts, fn {path, thresholds} ->
        suffix = mount_suffix(path)

        [
          %Rule{
            name: :"disk_usage_high_#{suffix}",
            domain: "System",
            severity: :warning,
            for_duration: 60_000,
            condition: fn -> check_disk_mount(path, thresholds.high) end
          },
          %Rule{
            name: :"disk_usage_critical_#{suffix}",
            domain: "System",
            severity: :emergency,
            for_duration: 0,
            condition: fn -> check_disk_mount(path, thresholds.critical) end
          }
        ]
      end)

    # Detect "/data not mounted" only if /data is configured for monitoring.
    # Unlocking the encrypted data volume is a manual step on boot, so a
    # brief unmount window is expected; `for_duration: 30_000` tolerates
    # that without paging on every reboot.
    mount_presence_rule =
      if Enum.any?(mounts, fn {path, _} -> path == "/data" end) do
        [
          %Rule{
            name: :data_volume_unmounted,
            domain: "System",
            severity: :critical,
            for_duration: 30_000,
            condition: fn -> check_data_volume_mounted() end
          }
        ]
      else
        []
      end

    mount_rules ++ mount_presence_rule
  end

  defp mount_suffix("/"), do: "root"

  defp mount_suffix(path),
    do: path |> String.trim_leading("/") |> String.replace("/", "_")

  # --- Rule Conditions ---

  @backlog_threshold 5

  defp check_resolution_backlog do
    threshold = get_config(:resolution_backlog_threshold, @backlog_threshold)

    case Cache.get(:resolution_backlog) do
      :unknown ->
        :ok

      %{count: count} when count > threshold ->
        {:alert, "count=#{count}, threshold=#{threshold}"}

      _ ->
        :ok
    end
  end

  defp check_cpu(:high) do
    pct = Metrics.cpu_usage()
    if pct > 80.0, do: {:alert, "usage=#{pct}%, threshold=80%"}, else: :ok
  end

  defp check_cpu(:critical) do
    pct = Metrics.cpu_usage()
    if pct > 95.0, do: {:alert, "usage=#{pct}%, threshold=95%"}, else: :ok
  end

  defp check_memory(:high) do
    pct = Metrics.memory_usage()
    if pct > 80.0, do: {:alert, "usage=#{pct}%, threshold=80%"}, else: :ok
  end

  defp check_memory(:critical) do
    pct = Metrics.memory_usage()
    if pct > 95.0, do: {:alert, "usage=#{pct}%, threshold=95%"}, else: :ok
  end

  defp check_disk_mount(path, threshold) do
    case Metrics.disk_usage(path) do
      pct when is_number(pct) and pct > threshold ->
        {:alert, "mount=#{path}, usage=#{pct}%, threshold=#{threshold}%"}

      _ ->
        :ok
    end
  end

  defp check_data_volume_mounted do
    case System.cmd("mountpoint", ["-q", "/data"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> {:alert, "/data is not mounted (encrypted volume unlock required?)"}
    end
  rescue
    _ -> :ok
  end

  defp check_tor_reachable do
    case tor_socks_latency_ms() do
      {:ok, _latency_ms} -> :ok
      {:error, _reason} -> {:alert, "port=#{tor_socks_port()}"}
    end
  end

  @tor_slow_threshold_ms 1_000

  defp check_tor_degraded do
    case tor_socks_latency_ms() do
      {:error, _reason} ->
        :ok

      {:ok, latency_ms} when latency_ms > @tor_slow_threshold_ms ->
        {:alert, "slow_socks=#{latency_ms}ms"}

      {:ok, _} ->
        :ok
    end
  end

  defp tor_socks_latency_ms do
    port = tor_socks_port()
    started = System.monotonic_time(:millisecond)

    case :gen_tcp.connect(~c"127.0.0.1", port, [], 2_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:ok, System.monotonic_time(:millisecond) - started}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp tor_socks_port do
    Application.get_env(:perpwalk, :tor, []) |> Keyword.get(:socks_port, 9050)
  end

  defp check_monero_reachable do
    case MoneroFacade.health_check() do
      :ok -> :ok
      {:error, reason} -> {:alert, "rpc=#{inspect(reason)}"}
    end
  end

  @monero_slow_threshold_ms 2_000

  # Monero wallet RPC is on loopback; a healthy `get_height` should
  # return in well under 100ms. > 2s sustained is either the wallet
  # refreshing under load, an overloaded monerod backing it, or the
  # host itself under I/O pressure — all worth surfacing before it
  # crosses into `:monero_unreachable`. Mirrors the `:tor_degraded`
  # latency-threshold pattern (1s on SOCKS handshake).
  defp check_monero_degraded do
    started = System.monotonic_time(:millisecond)

    case MoneroFacade.health_check() do
      :ok ->
        latency_ms = System.monotonic_time(:millisecond) - started

        if latency_ms > @monero_slow_threshold_ms do
          {:alert, "slow_rpc=#{latency_ms}ms"}
        else
          :ok
        end

      {:error, _} ->
        # Unreachable is a separate alert; don't double-fire here.
        :ok
    end
  end

  defp check_federation_quorum do
    if FederationFacade.quorum?() do
      :ok
    else
      online = FederationFacade.online_peer_count()
      n = FederationFacade.member_count()
      t = FederationFacade.threshold()
      {:alert, "peers=#{online}/#{n - 1} (need t-1=#{t - 1} for quorum)"}
    end
  end

  defp check_federation_signing_halted do
    if FederationFacade.halted?() do
      {:alert, "operator halt active"}
    else
      :ok
    end
  end

  # Payouts that hit a rule-engine rejection sit in `:awaiting_operator`
  # until the operator force-approves them via Console. They're invisible
  # to users (the LiveView shows "needs review"); without this alert the
  # operator has no signal that funds are stranded.
  defp check_payout_awaiting_operator do
    case FederationFacade.list_requests_by_status(:awaiting_operator) do
      [] ->
        :ok

      requests ->
        ids = Enum.map_join(requests, " ", &short_id(&1.id))
        {:alert, "count=#{length(requests)}, ids=#{ids}"}
    end
  end

  # Reads the most recent proof-of-reserves attestation round outcome
  # from `Reserves.Drift`. Divergent peers (responded but disagreed on
  # balance) indicate stale multisig info that the
  # `Monero.Multisig.Sync` mechanism hasn't reconciled yet. Distinct
  # from unreachable peers, which `:federation_quorum_lost` covers.
  defp check_federation_multisig_drift do
    case PerpWalk.Reserves.Drift.status() do
      %{divergent_peers: []} ->
        :ok

      %{divergent_peers: peers, observed_at: %DateTime{} = ts} ->
        ids = Enum.map_join(peers, " ", &inspect/1)
        {:alert, "count=#{length(peers)}, peer_ids=#{ids}, observed_at=#{DateTime.to_iso8601(ts)}"}
    end
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: "?"

  # Wall-clock VM uptime — the reserves-proof grace window measures
  # "has the pipeline EVER produced a proof" against it.
  defp vm_uptime_ms, do: :erlang.statistics(:wall_clock) |> elem(0)

  # Cycle interval is configurable; tolerate up to 3 misses before
  # alerting so an in-flight cycle that overruns slightly doesn't
  # page the operator.
  defp check_reserves_proof_stale do
    interval_ms = reserves_proof_interval_ms()
    threshold_ms = interval_ms * 3

    case PerpWalk.Reserves.Facade.latest_proof() do
      nil ->
        # Pre-first-cycle on a fresh boot is normal. Past the grace
        # window, a missing proof means the pipeline never produced
        # one — the venue's headline transparency mechanism would
        # otherwise stay silently dead forever.
        if vm_uptime_ms() > reserves_proof_interval_ms() + 60_000 do
          {:alert, "no proof produced since boot, uptime=#{div(vm_uptime_ms(), 60_000)}m"}
        else
          :ok
        end

      %Vault.Proof{snapshot: %{captured_at: captured_at}} ->
        age_ms =
          DateTime.utc_now()
          |> DateTime.diff(captured_at, :millisecond)

        if age_ms > threshold_ms do
          {:alert, "age=#{div(age_ms, 1_000)}s, threshold=#{div(threshold_ms, 1_000)}s"}
        else
          :ok
        end
    end
  rescue
    _ -> :ok
  end

  defp check_reserves_deficit do
    case PerpWalk.Reserves.Facade.solvency() do
      %{status: :active, delta_piconeros: delta} when delta < 0 ->
        {:alert, "deficit=#{abs(delta)} piconeros"}

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Bootstrap address mismatch is a one-shot event surfaced on the
  # EventBus. The Cache is updated by the Telemetry events handler
  # when a `BootstrapAddressMismatch` lands; until cleared by the
  # operator (re-running a successful bootstrap) the alert stays on.
  defp check_bootstrap_address_mismatch do
    case Cache.get(:bootstrap_address_mismatch) do
      %{addresses: addrs} when is_list(addrs) ->
        {:alert, "addresses=#{inspect(addrs)}"}

      _ ->
        :ok
    end
  end

  defp reserves_proof_interval_ms do
    # Default MUST match `PerpWalk.Reserves.Supervisor`'s
    # `@default_proof_interval_ms` (10 minutes) — otherwise the stale-
    # proof threshold (interval × 3) is shorter than the actual cycle
    # and we fire alerts on every healthy proof gap.
    Application.get_env(:perpwalk, :reserves, [])
    |> Keyword.get(:proof_interval_ms, 10 * 60 * 1_000)
  end

  # Monero wallet RPC starts to slow noticeably past ~1M
  # subaddresses on commodity hardware. High at 80%, critical at
  # 95% so operators have a window to migrate.
  @default_subaddress_high_threshold 800_000
  @default_subaddress_critical_threshold 950_000

  defp check_subaddress_index(level) do
    case Cache.get(:monero_subaddress_index) do
      :unknown ->
        :ok

      index when is_integer(index) ->
        config = Application.get_env(:perpwalk, :alerts_subaddress, [])

        high =
          Keyword.get(config, :high_threshold, @default_subaddress_high_threshold)

        critical =
          Keyword.get(config, :critical_threshold, @default_subaddress_critical_threshold)

        case level do
          :high when index >= high and index < critical -> {:alert, "index=#{index}"}
          :critical when index >= critical -> {:alert, "index=#{index}"}
          _ -> :ok
        end
    end
  rescue
    _ -> :ok
  end

  defp check_orphan_deposits do
    case PerpWalk.Monero.Orphans.count() do
      0 -> :ok
      n -> {:alert, "count=#{n}"}
    end
  rescue
    _ -> :ok
  end

  # Thresholds default to 500 entries (warning) and 5000 entries
  # (critical). At 1Hz × 1000 entries/batch backfill rate, a real
  # ongoing disconnection produces hundreds-of-thousands of unreplicated
  # entries within minutes; the warning fires well before that. 30s
  # `for_duration` rides out steady-state ticks where the follower
  # naturally trails by one batch.
  @replication_lag_warning_threshold 500
  @replication_lag_critical_threshold 5_000

  defp check_replication_lag(:warning), do: do_check_replication_lag(:warning_threshold)
  defp check_replication_lag(:critical), do: do_check_replication_lag(:critical_threshold)

  defp do_check_replication_lag(threshold_key) do
    threshold = get_config(threshold_key, default_replication_lag_threshold(threshold_key))

    case Cache.max_lag() do
      nil ->
        # No tick has landed yet — node just booted or the Replicator
        # hasn't completed its first cycle. Report `:ok` so the alert
        # doesn't latch on cold start.
        :ok

      lag when lag > threshold ->
        {:alert, "lag=#{lag}, threshold=#{threshold}"}

      _ ->
        :ok
    end
  end

  defp default_replication_lag_threshold(:warning_threshold), do: @replication_lag_warning_threshold
  defp default_replication_lag_threshold(:critical_threshold), do: @replication_lag_critical_threshold

  # Window after which a recorded rejection no longer counts as
  # "currently rejecting" — the Cache entry is sticky so the alert
  # poll can observe a rejection that fired between polls, but it
  # shouldn't latch forever if the leader recovers and rejections stop.
  @replication_batch_rejected_window_ms 60_000

  defp check_replication_batch_rejected do
    case Cache.get(:replication_batch_rejected) do
      :unknown ->
        :ok

      %{timestamp: ts, reason: reason} ->
        age_ms = DateTime.diff(DateTime.utc_now(), ts, :millisecond)

        if age_ms < @replication_batch_rejected_window_ms do
          {:alert, "reason=#{inspect(reason)}, age_ms=#{age_ms}"}
        else
          :ok
        end
    end
  end
end
