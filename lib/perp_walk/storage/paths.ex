defmodule PerpWalk.Storage.Paths do
  @moduledoc """
  Centralised, configurable data paths for all persistent storage.

  Modules call functions here rather than constructing paths themselves.
  The base directory is read from application config `:perpwalk, :data_dir`,
  which is sourced from `PERPWALK_DATA_DIR` at runtime.

  ## Directory Structure

  ```
  $PERPWALK_DATA_DIR/
    backups/
    keys/
    identity/
    markets/
    monero/
    storage/
      wal/
    telemetry/
  ```

  Domain subdirectories grow as those domains come online; this module
  is the single source of truth so adding a new sub-tree only requires
  updating one file.
  """

  # --- Base ---

  @spec base_dir() :: String.t()
  def base_dir, do: Application.get_env(:perpwalk, :data_dir, "data")

  # --- Context Directories ---

  @spec backups() :: String.t()
  def backups, do: Path.join(base_dir(), "backups")

  @spec keys() :: String.t()
  def keys, do: Path.join(base_dir(), "keys")

  @spec identity() :: String.t()
  def identity, do: Path.join(base_dir(), "identity")

  @spec markets() :: String.t()
  def markets, do: Path.join(base_dir(), "markets")

  @spec monero() :: String.t()
  def monero, do: Path.join(base_dir(), "monero")

  @spec reserves() :: String.t()
  def reserves, do: Path.join(base_dir(), "reserves")

  @spec storage() :: String.t()
  def storage, do: Path.join(base_dir(), "storage")

  @spec telemetry() :: String.t()
  def telemetry, do: Path.join(base_dir(), "telemetry")

  @spec federation() :: String.t()
  def federation, do: Path.join(base_dir(), "federation")

  # --- Storage ---

  @spec storage_wal() :: String.t()
  def storage_wal, do: Path.join(storage(), "wal")

  # Manual halt marker. When present, contains the halt reason. Loaded
  # into `:persistent_term` by `Telemetry.Health.System.load_persisted_halt/0`
  # on boot, so an operator-declared halt survives a BEAM restart.
  @spec storage_halt() :: String.t()
  def storage_halt, do: Path.join(storage(), "manual_halt")

  # --- Reserves ---

  @spec reserves_proofs() :: String.t()
  def reserves_proofs, do: Path.join(reserves(), "proofs.dets")

  # --- Keys ---

  @spec key_file(String.t()) :: String.t()
  def key_file(label), do: Path.join(keys(), "#{label}.enc")

  # --- Directory Management ---

  @doc """
  Creates the full directory tree. Call once on application startup
  before any supervisor starts. Each directory is created with
  owner-only permissions (0o700).
  """
  @spec ensure_dirs!() :: :ok
  def ensure_dirs! do
    dirs = [
      backups(),
      keys(),
      identity(),
      markets(),
      monero(),
      reserves(),
      storage(),
      storage_wal(),
      telemetry(),
      federation()
    ]

    Enum.each(dirs, fn dir ->
      File.mkdir_p!(dir)
      File.chmod(dir, 0o700)
    end)

    :ok
  end
end
