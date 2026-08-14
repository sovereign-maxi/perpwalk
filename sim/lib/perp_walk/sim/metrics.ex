defmodule PerpWalk.Sim.Metrics do
  @moduledoc """
  Atomic counter store for sim observables.

  Backed by a named public ETS table with `write_concurrency:
  true` so all actor processes and the engine can record metrics
  concurrently. Owned by a thin GenServer for table lifecycle —
  `start_link/1` creates the table; `reset/0` clears it between
  scenario runs.

  ## Standard metric names

  Counters use `{:metric, ...detail}` tuples as keys so the
  reporter can aggregate by detail dimension. Conventional
  metric families:

  - `{:market, :created}` / `{:market, :rejected}` /
    `{:market, :settled, outcome}` / `{:market, :voided, reason}`
  - `{:position, :opened}` / `{:position, :settled_winner}` /
    `{:position, :settled_loser}` / `{:position, :refunded}` /
    `{:position, :paid_out}`
  - `{:vote, direction}` for `:up` and `:down`
  - `{:dispute, :filed}` / `{:dispute, :live}` /
    `{:dispute, :resolved_for}` / `{:dispute, :resolved_against}` /
    `{:dispute, :cancelled}`
  - `{:payout, :requested}` / `{:payout, :submitted}` /
    `{:payout, :failed}`
  - `{:invariant, name, :checks}` / `{:invariant, name, :violations}`
  - `{:tick, :count}`

  Counters are best-effort — values may briefly drift under heavy
  concurrent writes between read and snapshot, but this is fine
  for a stress harness.
  """

  use GenServer

  @table __MODULE__

  # --- Public API ---

  @doc "Starts the metrics store and creates its named ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Increments `metric` by `n` (default 1). Returns the new value."
  @spec incr(term(), integer()) :: integer()
  def incr(metric, n \\ 1) do
    :ets.update_counter(@table, metric, {2, n}, {metric, 0})
  rescue
    ArgumentError -> 0
  end

  @doc "Returns the current value of `metric`, or 0 if not set."
  @spec get(term()) :: integer()
  def get(metric) do
    case :ets.lookup(@table, metric) do
      [{_key, v}] -> v
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc """
  Returns the full counter map. Used by the Reporter at run end
  to build the JSON summary.
  """
  @spec snapshot() :: %{term() => integer()}
  def snapshot do
    @table
    |> :ets.tab2list()
    |> Map.new()
  rescue
    ArgumentError -> %{}
  end

  @doc "Clears all counters. Sim runs call this between scenarios."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # --- GenServer ---

  @impl true
  def init(_opts) do
    create_table()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # --- Internal ---

  defp create_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

      _ref ->
        :ok
    end
  end
end
