defmodule PerpWalk.Telemetry.Health.System do
  @moduledoc """
  Aggregates component health into an overall system status.

  Statuses: `:healthy` → `:degraded` → `:critical` → `:halted`

  Re-evaluates every `interval_ms` (default 15s), reading active
  alerts from `Telemetry.Alerts.Manager` and deriving:
  - the overall status (worst-of)
  - per-component status map (used by admin footer pips)

  ## Halt model

  Two independent paths can put the system into `:halted`:

  1. **Manual** — `set_halted/1`, used during operator-led incident
     response. Survives a `Health.System` GenServer restart (the flag
     lives in `:persistent_term`, not in process state); only
     `clear_halt/0` clears it. **Does NOT survive a BEAM restart** —
     `:persistent_term` is in-memory only. If you need the halt to
     ride through a `systemctl restart perpwalk`, also set the
     operational tag externally (file marker, env var, etc.)
     or call `set_halted/1` again after boot.
  2. **Auto** — eval tick detects any `@halt_alerts` member active and
     writes the auto-halt key. Self-clears on the next tick when the
     condition resolves. Auto-halts re-arm naturally on BEAM restart
     because the eval tick re-evaluates the underlying alert.

  Both paths write to `:persistent_term`. `PerpWalk.Guards` reads those
  keys on every write to gate forward progress without a GenServer or
  ETS hop. See `PerpWalk.Guards` for the consumer side.
  """

  use GenServer

  require Logger

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Telemetry, as: TelemetryEvents
  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Storage.Paths
  alias PerpWalk.Telemetry.Alerts.Manager

  @table __MODULE__

  # Halt-class alerts that should put the whole system into `:halted`:
  #
  # - Disk-full conditions on root or /data: once monerod can't fsync or
  #   the WAL can't append, the safe posture is to stop taking new state
  #   changes rather than corrupt what's there.
  # - `/data` unmounted: the encrypted volume holds the multisig wallet
  #   keyshare; operating without it risks divergence.
  # - Federation quorum lost: without the t-of-n peer set the local
  #   node's sealed entries can't replicate to anyone; new state
  #   would only live on this node and be lost if it dies before
  #   quorum returns. Same divergence risk as a volume unmount,
  #   expressed at the cluster layer.
  @halt_alerts MapSet.new([
                 :disk_usage_critical_root,
                 :disk_usage_critical_data,
                 :data_volume_unmounted,
                 :federation_quorum_lost
               ])

  # Two persistent_term keys feed `PerpWalk.Guards`. Both are checked
  # on every write; either being set blocks writes.
  #
  # - `manual_halt`: written by `set_halted/1` (operator console during
  #   incident response). Survives restarts. Only `clear_halt/0` erases.
  # - `auto_halt`:   written by the eval tick when any `@halt_alerts`
  #   member is active. Erased by the eval tick when none are. Lives
  #   only while the underlying condition holds.
  #
  # Keeping them as separate keys means each writer owns its own state —
  # the eval tick can't accidentally clear an operator-initiated halt,
  # and operator clear/set can't race the eval tick's auto-halt logic.
  @manual_halt_key {__MODULE__, :manual_halt}
  @auto_halt_key {__MODULE__, :auto_halt}

  # Per-source auto-halt table. Distinct from `@auto_halt_key` (which
  # Health.System's tick derives from `@halt_alerts`). Subsystems that
  # need to raise a halt directly — Federation.Keys on pinning
  # mismatch, Storage.Replicator on peer signature failure,
  # Storage.WAL.Replay on malformed entry — write here, keyed by
  # source atom. Each source owns its own entry; clearing one source
  # never touches another.
  @source_halts_table :perpwalk_health_source_halts

  @type status :: :healthy | :degraded | :critical | :halted

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Current overall system status."
  @spec status() :: status()
  def status do
    if halted?() do
      :halted
    else
      case :ets.lookup(@table, :status) do
        [{:status, s}] -> s
        [] -> :healthy
      end
    end
  rescue
    ArgumentError -> :healthy
  end

  @doc """
  Fast boolean halt check. Used by `PerpWalk.Guards` on every write —
  two `:persistent_term.get/2` calls, sub-microsecond, no GenServer or
  ETS hop.
  """
  @spec halted?() :: boolean()
  def halted? do
    :persistent_term.get(@manual_halt_key, nil) != nil or
      :persistent_term.get(@auto_halt_key, nil) != nil or
      source_halt_count() > 0
  end

  @doc """
  Reason string for the current halt, or `nil` if not halted. Manual
  halt takes precedence — if the operator halted with a reason and an
  alert also fired, the operator's reason wins because it's the more
  specific one.
  """
  @spec halt_reason() :: String.t() | nil
  def halt_reason do
    case :persistent_term.get(@manual_halt_key, nil) do
      {true, reason} ->
        reason

      _ ->
        auto =
          case :persistent_term.get(@auto_halt_key, nil) do
            {true, r} -> [r]
            _ -> []
          end

        sources = source_halts() |> Map.values()

        case auto ++ sources do
          [] -> nil
          reasons -> Enum.join(reasons, "; ")
        end
    end
  end

  @doc """
  Sets an auto halt for `source` with `reason`. Each source occupies
  its own entry; setting `:federation_keys` never overwrites
  `:replicator`. Callers must pair this with `clear_source_halt(source)`
  when the condition resolves.

  Separate from the alert-derived `@auto_halt_key` which Health.System
  manages from `@halt_alerts` — source halts are for subsystems that
  need to raise a halt directly, not via a condition-polled alert rule.
  """
  @spec set_source_halt(atom(), String.t()) :: :ok
  def set_source_halt(source, reason) when is_atom(source) and is_binary(reason) do
    ensure_source_halts_table()
    :ets.insert(@source_halts_table, {source, reason})
    :ok
  end

  @doc "Clears the source-halt entry for `source`. Other sources are untouched."
  @spec clear_source_halt(atom()) :: :ok
  def clear_source_halt(source) when is_atom(source) do
    ensure_source_halts_table()
    :ets.delete(@source_halts_table, source)
    :ok
  end

  @doc "Snapshot of every active source halt, keyed by source atom."
  @spec source_halts() :: %{atom() => String.t()}
  def source_halts do
    ensure_source_halts_table()
    @source_halts_table |> :ets.tab2list() |> Map.new()
  end

  @doc "Per-component health status."
  @spec components() :: %{atom() => status()}
  def components do
    case :ets.lookup(@table, :components) do
      [{:components, c}] -> c
      [] -> default_components()
    end
  rescue
    ArgumentError -> default_components()
  end

  @doc "Sets the system to `:halted` with a reason (operator-initiated)."
  @spec set_halted(String.t()) :: :ok
  def set_halted(reason) do
    Logger.error("System: halted, reason=#{reason}")
    # Flag FIRST: a full disk is exactly when an operator halts, and the
    # file write raises there — flag-first ordering is the difference
    # between "halted, with boot-restore degraded" and "not halted at
    # all". The file write is still attempted for restart persistence.
    :persistent_term.put(@manual_halt_key, {true, reason})
    persist_manual_halt(reason)

    # Durable record in the operator audit log so a forensic review
    # can distinguish an operator-issued halt from an attacker on a
    # compromised credential calling the same function.
    FederationFacade.record_audit(:system_halt_set, %{
      reason: reason,
      at: DateTime.utc_now()
    })

    try do
      GenServer.call(__MODULE__, {:set_halted, reason}, 5_000)
    catch
      :exit, _ ->
        Logger.error("System: genserver unreachable, halt_via=persistent_term")
        :ok
    end
  end

  # Best-effort: log and continue on failure (ENOSPC). The halt flag
  # is already live; a lost file just means the next boot won't
  # restore it — and an unreadable file self-halts at boot anyway.
  defp persist_manual_halt(reason) do
    write_manual_halt_file!(reason)
  rescue
    e ->
      Logger.error("System: halt file persist failed, reason=#{inspect(e)} — halt holds in-memory only")
  end

  @doc """
  Clears an operator-initiated halt. Auto-halts from `@halt_alerts` are
  not cleared by this call — they clear themselves on the next eval
  tick once the underlying alert resolves.
  """
  @spec clear_halt() :: :ok
  def clear_halt do
    :ok = delete_manual_halt_file!()
    :persistent_term.erase(@manual_halt_key)

    FederationFacade.record_audit(:system_halt_cleared, %{
      at: DateTime.utc_now()
    })

    try do
      GenServer.call(__MODULE__, :clear_halt, 5_000)
    catch
      :exit, _ -> :ok
    end
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    table = :ets.new(@table, [:named_table, :protected, :set])
    interval = Keyword.get(opts, :interval_ms, get_config(:eval_interval_ms, 15_000))

    :ets.insert(table, {:status, :healthy})
    :ets.insert(table, {:components, default_components()})

    schedule_eval(interval)

    {:ok, %{table: table, interval_ms: interval, previous_status: :healthy}}
  end

  @impl true
  def handle_call({:set_halted, reason}, _from, state) do
    :ets.insert(state.table, {:status, :halted})
    :ets.insert(state.table, {:halt_reason, reason})
    publish_status_change(:halted)
    {:reply, :ok, %{state | previous_status: :halted}}
  end

  def handle_call(:clear_halt, _from, state) do
    :ets.insert(state.table, {:status, :healthy})
    :ets.delete(state.table, :halt_reason)
    publish_status_change(:healthy)
    {:reply, :ok, %{state | previous_status: :healthy}}
  end

  @impl true
  def handle_info(:evaluate, state) do
    readable? = Manager.readable?()
    alerts = Manager.active_alerts()

    {new_status, component_map} =
      if readable? do
        {derive_status(alerts), derive_components(alerts)}
      else
        # A crashed/restarting Manager makes active_alerts/0 rescue to
        # [] — treating that as "no alerts" would clear auto-halts and
        # report healthy mid-incident. Preserve halt state and surface
        # the pipeline failure as :critical instead.
        Logger.error("System: alerts manager unreadable — halt state preserved, status=:critical")
        {:critical, default_components()}
      end

    if readable?, do: sync_auto_halt(alerts)

    :ets.insert(state.table, {:status, new_status})
    :ets.insert(state.table, {:components, component_map})

    state =
      if new_status != state.previous_status do
        log_transition(state.previous_status, new_status)
        publish_status_change(new_status)
        %{state | previous_status: new_status}
      else
        state
      end

    schedule_eval(state.interval_ms)
    {:noreply, state}
  end

  # `persistent_term.put` triggers a global GC, so the value-equality
  # check below avoids paying that cost on ticks where the halt-class
  # alert set hasn't changed.
  @doc false
  def sync_auto_halt(alerts) do
    triggers =
      alerts
      |> Enum.filter(fn r -> MapSet.member?(@halt_alerts, r.name) end)
      |> Enum.map(& &1.name)

    case {triggers, :persistent_term.get(@auto_halt_key, nil)} do
      {[], nil} ->
        :ok

      {[], _existing} ->
        :persistent_term.erase(@auto_halt_key)
        Logger.warning("System: auto-halt cleared")

      {names, existing} ->
        reason = "halt-class alerts active: #{Enum.join(names, ", ")}"
        new_value = {true, reason}

        if existing != new_value do
          :persistent_term.put(@auto_halt_key, new_value)

          if existing == nil do
            Logger.error("System: auto-halt set, reason=#{reason}")
          end
        end

        :ok
    end
  end

  # --- Private ---

  defp derive_status(alerts) do
    cond do
      Enum.any?(alerts, fn r -> MapSet.member?(@halt_alerts, r.name) end) -> :halted
      Enum.any?(alerts, fn r -> r.severity in [:critical, :emergency] end) -> :critical
      Enum.any?(alerts, fn r -> r.severity == :warning end) -> :degraded
      true -> :healthy
    end
  end

  defp derive_components(alerts) do
    %{
      federation: component_status(alerts, [:federation_quorum_lost, :federation_signing_halted]),
      tor: component_status(alerts, [:tor_unreachable, :tor_degraded]),
      monero: component_status(alerts, [:monero_unreachable, :monero_degraded]),
      storage:
        component_status(alerts, [
          :disk_usage_high_root,
          :disk_usage_critical_root,
          :disk_usage_high_data,
          :disk_usage_critical_data,
          :data_volume_unmounted,
          :wal_disk_high
        ]),
      replication:
        component_status(alerts, [
          :peer_replication_lagging,
          :peer_replication_lagging_critical,
          :replication_batch_rejected
        ]),
      markets: component_status(alerts, [:resolution_backlog_high]),
      system: component_status(alerts, [:cpu_high, :cpu_critical, :memory_high, :memory_critical])
    }
  end

  defp component_status(alerts, relevant_names) do
    active = Enum.filter(alerts, &(&1.name in relevant_names))

    cond do
      active == [] -> :healthy
      Enum.any?(active, &(&1.severity == :emergency)) -> :halted
      Enum.any?(active, &(&1.severity == :critical)) -> :critical
      Enum.any?(active, &(&1.severity == :warning)) -> :degraded
      true -> :healthy
    end
  end

  defp log_transition(prev, current) do
    Logger.warning("System: health changed, from=#{prev}, to=#{current}")
  end

  defp publish_status_change(status) do
    EventBus.publish(%TelemetryEvents.SystemStatusChanged{
      status: status,
      timestamp: DateTime.utc_now()
    })
  end

  defp schedule_eval(interval) do
    Process.send_after(self(), :evaluate, interval)
  end

  defp default_components do
    %{
      tor: :healthy,
      monero: :healthy,
      storage: :healthy,
      replication: :healthy,
      markets: :healthy,
      system: :healthy
    }
  end

  defp get_config(key, default) do
    Application.get_env(:perpwalk, :telemetry, [])
    |> Keyword.get(key, default)
  end

  defp source_halt_count do
    ensure_source_halts_table()
    :ets.info(@source_halts_table, :size)
  end

  # Lazy-created source-halts table. `:public` + `write_concurrency`
  # allow subsystems to concurrently set/clear their own entries
  # without a GenServer bottleneck.
  defp ensure_source_halts_table do
    case :ets.whereis(@source_halts_table) do
      :undefined ->
        try do
          :ets.new(@source_halts_table, [
            :set,
            :public,
            :named_table,
            {:read_concurrency, true},
            {:write_concurrency, true}
          ])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  # --- Manual halt persistence ---

  @doc """
  Loads the persisted manual halt (if any) from disk into
  `:persistent_term`. Call from `Storage.Supervisor.init/1` after
  `Paths.ensure_dirs!/0` and before any write-path can execute.

  If the halt file is unreadable (permission denied, IO error), the
  system auto-halts with a diagnostic reason — fail-closed on
  ambiguous state is safer than assuming operational.
  """
  @spec load_persisted_halt() :: :ok
  def load_persisted_halt do
    case read_manual_halt_file() do
      {:ok, reason} ->
        :persistent_term.put(@manual_halt_key, {true, reason})
        Logger.warning("System: manual halt restored from disk, reason=#{reason}")
        :ok

      :missing ->
        :ok

      {:error, err} ->
        # A source halt, not the alert-managed auto-halt key: the eval
        # tick syncs the auto key from halt-class ALERTS and would
        # erase this within one tick. Source halts are operator-cleared.
        set_source_halt(:halt_file, "halt file unreadable: #{inspect(err)}")
        Logger.error("System: halt file unreadable, source-halting, reason=#{inspect(err)}")
        :ok
    end
  end

  # Atomic write via temp file + rename. A non-atomic File.write could
  # leave a partially-written file after a crash, which would deserialise
  # to an unintended reason string.
  @spec write_manual_halt_file!(String.t()) :: :ok
  defp write_manual_halt_file!(reason) do
    path = Paths.storage_halt()
    tmp = path <> ".tmp"
    File.write!(tmp, reason)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
    :ok
  end

  @spec delete_manual_halt_file!() :: :ok
  defp delete_manual_halt_file! do
    path = Paths.storage_halt()

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise "System: failed to delete halt file, reason=#{inspect(reason)}"
    end
  end

  @spec read_manual_halt_file() :: {:ok, String.t()} | :missing | {:error, term()}
  defp read_manual_halt_file do
    path = Paths.storage_halt()

    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end
end
