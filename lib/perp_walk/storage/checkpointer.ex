defmodule PerpWalk.Storage.Checkpointer do
  @moduledoc """
  Periodically writes a `:checkpoint` entry into the WAL.

  Each tick calls `Locker.WAL.checkpoint/1` which appends a
  checkpoint entry containing the current entry count and segment
  index. The marker is decorative for normal operation — the
  Markets and Federation stores filter checkpoints out during
  replay — but it gives the operator a stable "we definitely had
  consistent state at time T" boundary for pruning, audit, and
  future snapshot work.

  ## Why not auto-prune

  Locker can prune old segments via `Locker.WAL.prune/2`, but
  pruning is only safe when the in-memory state has been
  externally captured (snapshot file, replicated to another node,
  etc.). PerpWalk's state is purely WAL-derived right now — every
  segment is needed for cold-boot replay. This module ships
  checkpoint markers only; pruning stays operator-driven via
  `PerpWalk.Storage.Console.wal_prune/1`.

  ## Configuration

      config :perpwalk, :storage_checkpointer,
        interval_ms: 3_600_000,           # 1 hour
        wal_server: PerpWalk.Storage.WAL  # which WAL to checkpoint

  Tests set a multi-hour interval so the checkpointer effectively
  never fires; tests that exercise checkpointing call `run_now/0`
  for determinism.

  ## Telemetry

  - `[:perp_walk, :storage, :checkpointer, :ok]`
    measurements: `%{}`, metadata: `%{wal_server: atom()}`
  - `[:perp_walk, :storage, :checkpointer, :failed]`
    measurements: `%{}`, metadata: `%{wal_server: atom(), reason: term()}`
  """

  use GenServer

  require Logger

  @default_interval_ms 3_600_000
  @default_wal_server PerpWalk.Storage.WAL

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Force a synchronous checkpoint right now. Useful from iex and
  tests. Returns `:ok` even if the underlying WAL append failed —
  the failure is logged and emitted via telemetry. Callers that
  need to react to failure should subscribe to the telemetry events.
  """
  @spec run_now() :: :ok
  @spec run_now(GenServer.server()) :: :ok
  def run_now(server \\ __MODULE__), do: GenServer.call(server, :run_now, 30_000)

  # --- GenServer ---

  @impl true
  # Every hot node checkpoints its OWN local WAL in the symmetric
  # model — the WAL is per-node, not shared. A peer's checkpoint
  # markers replicate through and land in the local WAL alongside
  # the entries they bracket, but the local checkpoint marker is
  # what marks "this node's view of state at time T" for crash
  # recovery on this specific BEAM.
  def init(opts) do
    interval_ms =
      Keyword.get(opts, :interval_ms, get_config(:interval_ms, @default_interval_ms))

    wal_server =
      Keyword.get(opts, :wal_server, get_config(:wal_server, @default_wal_server))

    # Both hot nodes checkpoint their own local WAL independently in
    # the symmetric model; the WAL is per-node, not shared.
    state = %{interval_ms: interval_ms, wal_server: wal_server, active: true}
    schedule_tick(interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:run_now, _from, %{active: false} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:run_now, _from, state) do
    do_checkpoint(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    do_checkpoint(state)
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp do_checkpoint(state) do
    case safe_checkpoint(state.wal_server) do
      :ok ->
        :telemetry.execute(
          [:perp_walk, :storage, :checkpointer, :ok],
          %{},
          %{wal_server: state.wal_server}
        )

        Logger.debug("Checkpointer: wrote checkpoint, wal_server=#{inspect(state.wal_server)}")

      {:error, reason} ->
        :telemetry.execute(
          [:perp_walk, :storage, :checkpointer, :failed],
          %{},
          %{wal_server: state.wal_server, reason: reason}
        )

        Logger.warning(
          "Checkpointer: checkpoint failed, wal_server=#{inspect(state.wal_server)}, reason=#{inspect(reason)}"
        )
    end
  end

  defp safe_checkpoint(server) do
    Locker.WAL.checkpoint(server)
  catch
    :exit, reason -> {:error, {:wal_unavailable, reason}}
  end

  defp schedule_tick(interval_ms) when interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp get_config(key, default) do
    Application.get_env(:perpwalk, :storage_checkpointer, [])
    |> Keyword.get(key, default)
  end
end
