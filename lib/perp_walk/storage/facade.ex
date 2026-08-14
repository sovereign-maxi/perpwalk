defmodule PerpWalk.Storage.Facade do
  @moduledoc """
  Published Language facade for the Storage bounded context.

  This is the only legal cross-domain entry point for Storage
  functionality. Returns plain maps, tuples, and strings — never
  domain-internal structs.
  """

  alias Locker.WAL.Entry
  alias PerpWalk.Storage.{Encryption, Paths, WAL}
  alias PerpWalk.Storage.WAL.Sealer

  # --- WAL ---
  #
  # The Facade is the canonical entry for *cross-domain* WAL traffic —
  # callers that don't own a `:wal_server` handle. Per-domain Stores
  # that hold their own handle (test-isolated or otherwise) talk
  # directly to `Locker.WAL` against `state.wal_server`; they ARE
  # storage adapters, not consumers of storage.
  #
  # Seq + origin allocation for every WAL entry — including writes
  # from the per-domain stores — flows through `seal_and_append/2-3`
  # or `seal/1` here. The underlying `Storage.WAL.Sealer` enforces
  # the "every entry carries an (:origin, :seq) composite key"
  # invariant that the bi-directional Replicator relies on for
  # dedup + author attribution.

  @doc """
  Allocates the next global seq, seals `payload` with it, and appends
  the wrapped entry to the unified WAL. Cross-domain entry point for
  the seq-enforced write path.

  This is the ONLY public write surface on the Facade. Earlier
  `write_wal/2` and `append_wal_entry/1` helpers bypassed the
  Sealer, producing unsigned + unsealed entries that peers would
  refuse on the replication path but that boot replay accepted as
  "grandfathered". They had zero production callers so their
  removal is safe; keeping the loaded-but-unused unsealed surface
  is a latent forgery vector — a future refactor pointing at
  either function would silently write forgery-legal WAL entries.
  """
  @spec seal_and_append(atom(), map()) :: :ok | {:error, term()}
  defdelegate seal_and_append(type, payload), to: Sealer

  @doc """
  Domain-store variant of `seal_and_append/2`. Per-domain stores that
  own a `:wal_server` handle (test-isolated or otherwise) pass it in
  so the seal-and-append targets their owned WAL rather than the
  default singleton. The seq still comes from the central counter.
  """
  @spec seal_and_append(atom(), map(), GenServer.server()) :: :ok | {:error, term()}
  defdelegate seal_and_append(type, payload, wal_server), to: Sealer

  @doc """
  Allocates the next global seq, stamps `payload` with `:origin` +
  `:seq`, and Ed25519-signs the result under `type`. Returns the
  sealed+signed payload to the caller. For producers with custom
  append-side handling (retry loops, batched writes) that still need
  central seq allocation AND the federated-mode signing guarantee.

  Returns `{:error, :no_signing_key}` in federated mode with no
  local signing key — matches `seal_and_append/2-3`'s strictness so
  the direct-append path cannot bypass the fed-mode signing check.
  """
  @spec seal(atom(), map()) :: {:ok, map()} | {:error, :no_signing_key}
  defdelegate seal(type, payload), to: Sealer

  @doc """
  Returns the current global WAL seq — the seq of the last allocation
  or 0 if nothing has been allocated since boot. Read-only; safe to
  call from any process. Used by the daily heartbeat as a proof-of-life
  signal for replication.
  """
  @spec current_wal_seq() :: non_neg_integer()
  defdelegate current_wal_seq(), to: Sealer, as: :current_seq

  @doc """
  Advances the global WAL seq counter to at least `target`. Called
  by the `Replicator` after applying a remote batch so the local
  counter stays current with the global seq tip across all peers.
  """
  @spec bump_wal_seq(non_neg_integer()) :: :ok
  defdelegate bump_wal_seq(target), to: Sealer, as: :bump_to

  @doc "Reads all WAL entries currently on disk."
  @spec read_all_wal() :: {:ok, [Entry.t()]} | {:error, term()}
  def read_all_wal, do: Locker.WAL.read_all(WAL)

  @doc """
  WAL stats — entry count, byte size, current segment index, etc.
  Read-only observation; used by Telemetry's health cache.
  """
  @spec wal_info() :: map()
  def wal_info do
    Locker.WAL.info(WAL)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  # --- Encryption ---

  @doc """
  Encrypts a binary value with the configured master key.

  Pass an `aad` label (e.g. `"reserves-nostr-key-v1"`) so each
  at-rest record's ciphertext is bound to its purpose — an
  attacker who can write under /data cannot swap one encrypted
  record for another that shares the default AAD without decrypt
  failing on tag mismatch.
  """
  @spec encrypt(binary()) :: {:ok, binary()} | {:error, term()}
  @spec encrypt(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  defdelegate encrypt(data), to: Encryption
  defdelegate encrypt(data, aad), to: Encryption

  @doc """
  Decrypts a binary value with the configured master key. `aad`
  MUST match the label passed at encrypt time.
  """
  @spec decrypt(binary()) :: {:ok, binary()} | {:error, term()}
  @spec decrypt(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  defdelegate decrypt(data), to: Encryption
  defdelegate decrypt(data, aad), to: Encryption

  @doc "Encrypts an Erlang term."
  @spec encrypt_term(term()) :: {:ok, binary()} | {:error, term()}
  @spec encrypt_term(term(), binary()) :: {:ok, binary()} | {:error, term()}
  defdelegate encrypt_term(term), to: Encryption
  defdelegate encrypt_term(term, aad), to: Encryption

  @doc "Decrypts an Erlang term."
  @spec decrypt_term(binary()) :: {:ok, term()} | {:error, term()}
  @spec decrypt_term(binary(), binary()) :: {:ok, term()} | {:error, term()}
  defdelegate decrypt_term(data), to: Encryption
  defdelegate decrypt_term(data, aad), to: Encryption

  # --- Paths ---

  @doc "Base data directory."
  @spec base_dir() :: binary()
  defdelegate base_dir(), to: Paths

  @doc "Backup directory."
  @spec backup_dir() :: binary()
  def backup_dir, do: Paths.backups()

  @doc "Encrypted key file path for the given label."
  @spec key_file(String.t()) :: binary()
  defdelegate key_file(label), to: Paths

  @doc "Identity domain data directory."
  @spec identity_dir() :: binary()
  def identity_dir, do: Paths.identity()

  @doc "Markets domain data directory."
  @spec markets_dir() :: binary()
  def markets_dir, do: Paths.markets()

  @doc "Monero domain data directory."
  @spec monero_dir() :: binary()
  def monero_dir, do: Paths.monero()

  @doc "Federation domain data directory."
  @spec federation_dir() :: binary()
  def federation_dir, do: Paths.federation()

  @doc "DETS file path for the orphan deposit ledger."
  @spec monero_orphans_path() :: binary()
  def monero_orphans_path, do: Path.join(Paths.monero(), "orphans.dets")

  @doc "Keys directory (for encrypted signing-key files)."
  @spec keys_path() :: binary()
  def keys_path, do: Paths.keys()

  @doc "DETS file path for the reserves proof history."
  @spec reserves_proofs_path() :: binary()
  def reserves_proofs_path, do: Paths.reserves_proofs()

  @doc "Telemetry domain data directory."
  @spec telemetry_dir() :: binary()
  def telemetry_dir, do: Paths.telemetry()

  @doc "Creates the full data directory tree. Called once at boot."
  @spec ensure_dirs!() :: :ok
  defdelegate ensure_dirs!(), to: Paths
end
