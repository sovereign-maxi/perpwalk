defmodule PerpWalk.Storage.Recovery do
  @moduledoc """
  Boot-time recovery pipeline.

  On startup, reads every WAL entry and dispatches it to the appropriate
  domain rebuilder so in-memory state can be reconstructed before
  serving traffic.

  Rebuilders are registered per domain via `register_rebuilder/2` (a
  module that implements `apply_entry/1`). The pipeline halts startup
  on any unrecoverable corruption rather than silently skipping
  entries — corruption is an operational concern, not something the
  recovery layer hides.

  This module is a skeleton in the bootstrap. Real per-domain
  rebuilders attach as Markets, Identity, Monero, etc come online.
  """

  alias PerpWalk.Storage.WAL

  require Logger

  # --- Public API ---

  @doc """
  Replays the WAL and rebuilds in-memory state.

  Returns:
  - `{:ok, %{entries_replayed: n}}` on success
  - `{:error, reason}` if any step fails — startup must halt
  """
  @spec run() :: {:ok, map()} | {:error, term()}
  def run do
    Logger.info("Recovery: starting WAL replay")

    case Locker.WAL.read_all_strict(WAL.server_name()) do
      {:ok, entries} ->
        replay(entries)

      {:error, reason} ->
        Logger.error("Recovery: WAL read failed, reason=#{inspect(reason)}")
        {:error, {:wal_read_failed, reason}}
    end
  end

  # --- Internal ---

  # No domain rebuilders registered yet — the bootstrap WAL has no
  # entry types defined. As domains come online, this function will
  # dispatch each entry to the relevant rebuilder and short-circuit
  # with `{:error, _}` on dispatch failure.
  defp replay(entries) do
    count = length(entries)
    Logger.info("Recovery: WAL replay complete, total=#{count}, applied=#{count}")
    {:ok, %{entries_replayed: count}}
  end
end
