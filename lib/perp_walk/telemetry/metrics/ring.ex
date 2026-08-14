defmodule PerpWalk.Telemetry.Metrics.Ring do
  @moduledoc """
  In-memory ring buffer for system metrics time series.

  Stores the last 360 snapshots (6h at 1-minute intervals) in ETS
  for zero-latency reads from the admin dashboard. Snapshots come
  from `Telemetry.Health.Metrics.snapshot/0`. Data does not survive
  restarts — operational charts start fresh, which is acceptable
  since we are not auditing history here, just watching trends.

      Ring.latest()                # %{cpu_pct: 12.3, memory_pct: 45.7, ...}
      Ring.series(:cpu_pct, 60)    # [{ts, val}, ...] oldest-first
  """

  use GenServer

  alias PerpWalk.Telemetry.Health.Metrics

  @table __MODULE__
  @max_entries 360
  @tick_interval_ms 60_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Most recent metrics snapshot, or nil if the ring isn't running."
  @spec latest() :: map() | nil
  def latest do
    case :ets.lookup(@table, :latest) do
      [{:latest, snapshot}] -> snapshot
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Time series for a metric key — list of `{unix_timestamp, value}`
  oldest-first, capped at `limit` entries.
  """
  @spec series(atom(), pos_integer()) :: [{integer(), number()}]
  def series(key, limit \\ @max_entries) do
    case :ets.lookup(@table, :index) do
      [{:index, current_idx}] ->
        start_idx = max(0, current_idx - limit + 1)

        start_idx..current_idx
        |> Enum.reduce([], fn idx, acc ->
          case :ets.lookup(@table, {:entry, rem(idx, @max_entries)}) do
            [{{:entry, _}, ts, snapshot}] ->
              value = Map.get(snapshot, key, 0)
              [{ts, value} | acc]

            [] ->
              acc
          end
        end)
        |> Enum.reverse()

      [] ->
        []
    end
  rescue
    ArgumentError -> []
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(table, {:index, -1})

    record_snapshot(table, 0)
    schedule_tick()

    {:ok, %{table: table, index: 0}}
  end

  @impl true
  def handle_info(:tick, state) do
    new_index = state.index + 1
    record_snapshot(state.table, new_index)
    schedule_tick()
    {:noreply, %{state | index: new_index}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp record_snapshot(table, index) do
    snapshot = Metrics.snapshot()
    ts = System.system_time(:second)
    slot = rem(index, @max_entries)

    :ets.insert(table, {{:entry, slot}, ts, snapshot})
    :ets.insert(table, {:latest, snapshot})
    :ets.insert(table, {:index, index})
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end
end
