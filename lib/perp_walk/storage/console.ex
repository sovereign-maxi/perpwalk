defmodule PerpWalk.Storage.Console do
  @moduledoc """
  Operator-only iex commands for inspecting and maintaining the WAL.

  These functions are intended to be called from a remote console
  (`bin/perpwalk remote`) by the operator. None of them are wired
  to a LiveView surface — destructive WAL operations should never
  be one click away from a public page.

  ## Commands

  - `wal_info/0` — current segment, entry count, bytes written.
  - `wal_checkpoint/0` — write a checkpoint marker now.
  - `wal_rotate/0` — force a new segment file.
  - `wal_prune/1` — delete old segment files, keeping the most
    recent N. **Destructive** — only safe when state has been
    captured externally (today: never; replay walks every
    segment). Use with caution.

  See the matching `Markets.Console` and `Federation.Console`
  modules for the same operator pattern in the application
  domains.
  """

  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Storage.{Checkpointer, Paths, WAL}

  @doc "Returns WAL state info: segment, entry count, bytes."
  @spec wal_info() :: map()
  def wal_info do
    Locker.WAL.info(WAL.server_name())
  end

  @doc """
  Writes a `:checkpoint` entry into the WAL via the Checkpointer
  GenServer (so telemetry fires alongside the manual call). Also
  works when called by the periodic tick — the GenServer
  serialises both paths.
  """
  @spec wal_checkpoint() :: :ok
  def wal_checkpoint, do: Checkpointer.run_now()

  @doc """
  Forces a rotation to a new WAL segment file. Useful after a
  large bulk operation when the operator wants the just-written
  data in its own segment for archival.
  """
  @spec wal_rotate() :: :ok | {:error, term()}
  def wal_rotate do
    case Locker.WAL.rotate(WAL.server_name()) do
      :ok ->
        FederationFacade.record_audit(:wal_rotated, %{at: DateTime.utc_now()})
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Deletes the oldest WAL segments, keeping the most recent
  `keep` (default 10). Returns `{:ok, pruned_count}`.

  **Destructive.** PerpWalk's state is currently rebuilt by
  replaying every segment on cold boot — pruning here means losing
  the deleted history. Only run this if you've taken an external
  snapshot (e.g. cluster replication has caught up to the kept
  range) or you're deliberately discarding old state.
  """
  @spec wal_prune(pos_integer()) :: {:ok, non_neg_integer()} | {:error, :cancelled}
  def wal_prune(keep \\ 10) when is_integer(keep) and keep >= 1 do
    IO.puts("""

    wal_prune will delete segments older than the most-recent #{keep}.
    PerpWalk replays every segment on cold boot — pruned history is
    NOT recoverable without an external backup.
    """)

    case IO.gets("Proceed? (yes/N) ") do
      "yes\n" ->
        case Locker.WAL.prune(Paths.storage_wal(), keep) do
          {:ok, pruned} = ok ->
            FederationFacade.record_audit(:wal_pruned, %{keep: keep, pruned: pruned, at: DateTime.utc_now()})
            ok
        end

      _ ->
        IO.puts("Cancelled.")
        {:error, :cancelled}
    end
  end
end
