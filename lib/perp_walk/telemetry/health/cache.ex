defmodule PerpWalk.Telemetry.Health.Cache do
  @moduledoc """
  Event-subscribed cache of cross-domain health state.

  Alert rules read from the cache instead of polling other domains
  directly — keeps the rule layer fast and decoupled from domain
  facades. Populated by EventBus subscriptions plus periodic polls
  for state that isn't event-driven.

  ## Cached keys

  - `:resolution_backlog` — `%{count: integer, timestamp: DateTime}`
    derived from the markets list every poll. Used by the
    `:resolution_backlog_high` rule and shown in the admin sub-nav.
  - `:wal_info` — `%{entry_count, bytes_written, segment_index}` from
    `Locker.WAL.info/1`. Used by future WAL alerts.
  - `:bootstrap_address_mismatch` — `%{addresses: [String.t()],
    timestamp: DateTime}` populated from the EventBus when the
    federation ceremony detects guardian-reported address divergence.
    Sticky until manually cleared via `clear/1` after a successful
    re-bootstrap.
  - `{:replicator_tick, peer_id}` — `%{cursor, peer_tip, lag,
    batch_size, result, timestamp: DateTime}` from the bi-directional
    `Storage.Replicator` per-peer tick. One row per peer the local
    node is pulling from. Used by the `:peer_replication_lagging`
    rule via `max_lag/0`.
  - `:replication_batch_rejected` — `%{count, reason, timestamp}`
    populated from the `[:perp_walk, :storage, :replicator,
    :batch_rejected]` telemetry event. Sticky for one minute so the
    alert rule has time to observe — re-set on every rejection.
  """

  use GenServer

  require Logger

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Storage.Facade, as: StorageFacade

  @table __MODULE__
  @poll_interval_ms 15_000

  @backlog_statuses [:expired, :resolving]

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Cached value for `key`, or `:unknown` if not yet populated."
  @spec get(term()) :: term()
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  @doc "Drop a sticky cache entry — used by the operator console to clear bootstrap alerts after a successful re-run."
  @spec clear(term()) :: :ok
  def clear(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Drops every per-peer replicator-tick entry. Used by scenario tests
  to reset state between cases — production code shouldn't need this
  because new ticks overwrite the per-peer rows on every cycle.
  """
  @spec clear_replicator_ticks() :: :ok
  def clear_replicator_ticks do
    :ets.match_delete(@table, {{:replicator_tick, :_}, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Returns the largest per-peer `lag` value observed across all peers
  whose replicator ticks have landed, or `nil` if no tick has been
  recorded yet. Used by the `:peer_replication_lagging` rules.
  """
  @spec max_lag() :: non_neg_integer() | nil
  def max_lag do
    case :ets.match(@table, {{:replicator_tick, :_}, :"$1"}) do
      [] ->
        nil

      rows ->
        rows
        |> List.flatten()
        |> Enum.map(& &1.lag)
        |> Enum.max(fn -> nil end)
    end
  rescue
    ArgumentError -> nil
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    # Public access so telemetry handlers (which run in the caller's
    # process, not this GenServer) can write directly. Reads stay
    # cheap; writes are all single-key replacements so concurrent
    # writers can't tangle a record.
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    EventBus.subscribe(FederationEvents.BootstrapAddressMismatch)

    # Subaddress index updates flow as :telemetry events from
    # Monero.Facade.create_subaddress/0 — gauge style, last write wins.
    :telemetry.attach(
      "perpwalk-cache-subaddress-index",
      [:perp_walk, :monero, :subaddress, :allocated],
      &__MODULE__.handle_telemetry/4,
      nil
    )

    # Bi-directional replicator tick: cursor / peer_tip / lag / result
    # — one event per peer per tick, keyed by `peer:` in metadata.
    :telemetry.attach(
      "perpwalk-cache-replicator-tick",
      [:perp_walk, :storage, :replicator, :tick],
      &__MODULE__.handle_telemetry/4,
      nil
    )

    # Batch rejections — stickier so the alert rule can observe a
    # rejection that happened seconds before its evaluation poll.
    :telemetry.attach(
      "perpwalk-cache-replication-batch-rejected",
      [:perp_walk, :storage, :replicator, :batch_rejected],
      &__MODULE__.handle_telemetry/4,
      nil
    )

    poll_now()
    schedule_poll()
    {:ok, %{}}
  end

  @doc false
  def handle_telemetry([:perp_walk, :monero, :subaddress, :allocated], %{index: index}, _meta, _) do
    safe_insert({:monero_subaddress_index, index})
  end

  def handle_telemetry(
        [:perp_walk, :storage, :replicator, :tick],
        %{cursor: cursor, peer_tip: peer_tip, lag: lag, batch_size: batch_size},
        %{peer: peer} = meta,
        _
      ) do
    safe_insert(
      {{:replicator_tick, peer},
       %{
         cursor: cursor,
         peer_tip: peer_tip,
         lag: lag,
         batch_size: batch_size,
         result: Map.get(meta, :result, :unknown),
         timestamp: DateTime.utc_now()
       }}
    )
  end

  def handle_telemetry(
        [:perp_walk, :storage, :replicator, :batch_rejected],
        %{count: count},
        meta,
        _
      ) do
    safe_insert(
      {:replication_batch_rejected, %{count: count, reason: Map.get(meta, :reason), timestamp: DateTime.utc_now()}}
    )
  end

  # Defensive insert: the telemetry event can fire before the Cache
  # GenServer has created its ETS table during application boot, or
  # in contexts where the Cache isn't started. Drop the value rather
  # than detaching the handler.
  defp safe_insert(record) do
    :ets.insert(@table, record)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def handle_info(:poll, state) do
    poll_now()
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(%FederationEvents.BootstrapAddressMismatch{addresses: addrs}, state) do
    :ets.insert(
      @table,
      {:bootstrap_address_mismatch, %{addresses: addrs, timestamp: DateTime.utc_now()}}
    )

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp poll_now do
    poll_resolution_backlog()
    poll_wal_info()
  end

  defp poll_resolution_backlog do
    count =
      MarketsFacade.list_markets()
      |> Enum.count(&(&1.status in @backlog_statuses))

    :ets.insert(@table, {:resolution_backlog, %{count: count, timestamp: DateTime.utc_now()}})
  rescue
    e ->
      Logger.warning("Cache: backlog poll failed, reason=#{inspect(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp poll_wal_info do
    info = StorageFacade.wal_info()
    :ets.insert(@table, {:wal_info, info})
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end
end
