defmodule PerpWalk.Storage.WAL.Sealer do
  @moduledoc """
  Central seq-allocating wrapper around `Locker.WAL.append/2`.

  Every entry written to the unified WAL MUST carry both an
  `:origin` (the writing node's `Role.participant_id/0`) and a
  strictly-monotonically-increasing `:seq` field in its payload.
  The composite `(origin, seq)` is the globally unique key used by
  the bi-directional `Storage.Replicator` to dedup and verify
  entries received from peers. The Sealer is the single
  producer-side enforcement point: callers hand it a type + a
  payload, it stamps origin + the next per-origin seq, and appends
  the wrapped entry.

  ## Why centralised

  Before this module existed, each domain store (`Markets.Store`,
  `Federation.Store`, `Identity.Sessions`) maintained its own seq
  accounting. Adding a new producer that forgot to seal a payload —
  for example, `Identity.Sessions.append_wal/2` writing
  `:session_created` with a bare `%{sid: ..., account_id: ...}` —
  silently broke replication: the receiving peer halted on the
  first seqless entry past its cursor, the cursor stayed put,
  every subsequent tick re-fetched the same wedged batch.

  Centralising into one module makes the invariant impossible to
  forget. New producers either use the Sealer or fail their own type
  registration; they cannot write to the WAL without going through
  the seal step.

  ## Initialisation

  On boot the Sealer scans the local WAL once and finds the maximum
  `:seq` value across every payload it can decode. The atomics counter
  starts at that maximum so the first allocation after boot returns
  `max + 1`. On a fresh boot (empty WAL) the counter starts at 0 and
  the first allocation returns 1.

  The Replicator bumps the counter via `bump_to/1` after applying
  each remote batch so the local counter stays current with peers'
  global seq tip. This guarantees a future locally-allocated seq
  is never lower than the highest seq this node has observed from
  any origin — keeping per-node seqs monotonic within each origin
  and avoiding surprising operator-inspection results.

  ## Atomicity

  The counter is a 1-cell `:atomics` reference. `:atomics.add_get/3`
  is wait-free across schedulers so concurrent direct-path writers
  (Markets `direct_write`, etc.) get unique seqs without locking.
  `:atomics.compare_exchange/4` powers the CAS loop in `bump_to/1`
  so concurrent replication batches landing slightly out of order
  cannot rewind the counter.
  """

  use GenServer

  alias Locker.WAL.Entry
  alias PerpWalk.Storage.WAL.Signing

  require Logger

  @persistent_key {__MODULE__, :counter_ref}
  @default_wal_server PerpWalk.Storage.WAL
  @unsigned_warned_key {__MODULE__, :unsigned_warned}

  # --- Public API ---

  @doc """
  Starts the Sealer GenServer. Children of the Storage supervisor.
  The boot init scans the configured WAL for the global max seq.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Allocates the next global seq, seals `payload` with it, and appends
  `%Entry{type: type, payload: sealed}` to the WAL via
  `Locker.WAL.append/2`.

  Returns `:ok` or `{:error, reason}` straight from the WAL append.
  Sealed payloads include `seq:` even if the caller passed one
  explicitly — the caller's value is overwritten so producers cannot
  forge a seq that conflicts with the global counter.
  """
  @spec seal_and_append(atom(), map()) :: :ok | {:error, term()}
  @spec seal_and_append(atom(), map(), GenServer.server()) ::
          :ok | {:error, :no_signing_key | term()}
  def seal_and_append(type, payload, wal_server \\ @default_wal_server)
      when is_atom(type) and is_map(payload) do
    sealed = stamp(payload)

    case sign_or_pass_through(type, sealed) do
      {:ok, payload_to_write} ->
        entry = %Entry{type: type, payload: payload_to_write}
        Locker.WAL.append(wal_server, entry)

      {:error, :no_signing_key} = err ->
        Logger.error(
          "Sealer: refusing to write unsigned #{inspect(type)} entry — " <>
            "pinned pubkey registry is non-empty (federated mode) but " <>
            "Cartel is not exposing a local signing key. Check that " <>
            "PERPWALK_NODE_PASSPHRASE is set and Cartel booted cleanly."
        )

        err
    end
  end

  # Symmetric with the peer-side Replicator's strictness. Two modes:
  #
  #   Federated (pinned_pubkeys non-empty): signing is REQUIRED. Missing
  #   local key returns `{:error, :no_signing_key}` — fail-fast at the
  #   writer so peers never see an unsigned entry to halt on. This
  #   inverts an earlier asymmetry where the writer silently emitted
  #   unsigned entries that peers then halted on.
  #
  #   Single-node (pinned_pubkeys empty): signing is OPTIONAL. Missing
  #   local key writes an unsigned entry with a one-time warning —
  #   preserves dev/test boot ergonomics where no signing key exists
  #   and no peers verify.
  defp sign_or_pass_through(type, sealed) do
    case Signing.sign_entry(type, sealed) do
      {:ok, sig} ->
        {:ok, Map.put(sealed, :sig, sig)}

      {:error, :not_found} ->
        if signing_enforced?() do
          {:error, :no_signing_key}
        else
          warn_unsigned_once()
          {:ok, sealed}
        end
    end
  end

  # Federated mode is inferred from the pinned pubkey registry, the
  # same signal the Replicator's verify path uses. If any participant
  # is pinned, peers will reject unsigned entries, so writes must sign.
  defp signing_enforced?, do: PerpWalk.Federation.Keys.pinned_pubkeys() != %{}

  defp warn_unsigned_once do
    if :persistent_term.get(@unsigned_warned_key, false) do
      :ok
    else
      Logger.warning("Sealer: no local signing key, entries will be unsigned (single-node mode)")
      :persistent_term.put(@unsigned_warned_key, true)
      :ok
    end
  end

  @doc """
  Returns the current counter value — the seq of the last allocation,
  or 0 if nothing has been allocated since boot. Read-only; safe to
  call from any process. Used by `Markets.Store.wal_info/0` and the
  daily heartbeat.
  """
  @spec current_seq() :: non_neg_integer()
  def current_seq do
    case fetch_ref() do
      {:ok, ref} -> :atomics.get(ref, 1)
      :error -> 0
    end
  end

  @doc """
  Allocates the next seq, stamps `payload` with `:origin` + `:seq`,
  and Ed25519-signs the result under `type` with the local federation
  key. Returns the sealed+signed payload to the caller. Used by
  producers that need to do their own appending (custom retry logic,
  batched writes) but still want central seq allocation and the
  federated-mode signing guarantee.

  Symmetric with `seal_and_append/2-3`:
  - Federated mode (pinned pubkeys non-empty) + no local key →
    `{:error, :no_signing_key}`. Fail-fast at the writer so peers
    never see an unsigned entry to halt on.
  - Single-node mode (no pinned pubkeys) → `{:ok, sealed}` with an
    unsigned payload and a one-time warning; preserves dev/test
    ergonomics.

  The caller's existing `:seq` field, if present, is overwritten.
  """
  @spec seal(atom(), map()) :: {:ok, map()} | {:error, :no_signing_key}
  def seal(type, payload) when is_atom(type) and is_map(payload) do
    payload |> stamp() |> then(&sign_or_pass_through(type, &1))
  end

  # Bi-directional replication needs every entry to declare its
  # writer so the recipient node can dedup by (origin, seq) — the
  # composite key. Stamping happens centrally here so a future
  # producer that forgets to set `:origin` is impossible to introduce.
  defp stamp(payload) do
    payload
    |> Map.put(:seq, next_seq())
    |> Map.put(:origin, PerpWalk.Role.participant_id())
  end

  @doc """
  Advances the counter to at least `target` (idempotent on
  `target <= current`). Called by the bi-directional `Replicator`
  after applying a remote batch so the local counter stays current
  with the global seq tip across all peers — preventing a future
  locally-allocated seq from sitting below an already-observed
  remote one.

  CAS-loop: concurrent callers cannot rewind the counter to a lower
  value than another caller has already set.
  """
  @spec bump_to(non_neg_integer()) :: :ok
  def bump_to(target) when is_integer(target) and target >= 0 do
    case fetch_ref() do
      {:ok, ref} -> do_bump(ref, target)
      :error -> :ok
    end
  end

  @doc """
  Test-only: resets the counter to 0. Called from `clean_state` to
  isolate per-test seq accounting. NEVER call from production code —
  resetting the counter while real writes are in flight would
  collapse seq monotonicity.
  """
  @spec reset!() :: :ok
  def reset! do
    case fetch_ref() do
      {:ok, ref} ->
        :atomics.put(ref, 1, 0)
        :ok

      :error ->
        :ok
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    wal_server = Keyword.get(opts, :wal_server, @default_wal_server)
    max_seq = scan_for_max_seq(wal_server)

    # Init order matters: set the atomics cell BEFORE publishing the
    # ref to persistent_term so any reader that picks up the ref via
    # `fetch_ref/0` reads the correct max_seq, not the default 0
    # value `:atomics.new/2` leaves the cell at. In practice the
    # storage supervisor's `rest_for_one` strategy means no producer
    # can call `next_seq/0` before this returns, but ordering the
    # writes correctly removes the defense-in-depth gap regardless.
    ref =
      case :persistent_term.get(@persistent_key, nil) do
        nil ->
          new_ref = :atomics.new(1, [])
          :atomics.put(new_ref, 1, max_seq)
          :persistent_term.put(@persistent_key, new_ref)
          new_ref

        existing ->
          :atomics.put(existing, 1, max_seq)
          existing
      end

    Logger.info("Sealer: initialised, max_seq=#{max_seq}, wal_server=#{inspect(wal_server)}")

    {:ok, %{ref: ref, wal_server: wal_server}}
  end

  # --- Internal ---

  defp next_seq do
    case fetch_ref() do
      {:ok, ref} -> :atomics.add_get(ref, 1, 1)
      :error -> raise "Storage.WAL.Sealer: counter not initialised — boot order bug"
    end
  end

  defp fetch_ref do
    case :persistent_term.get(@persistent_key, nil) do
      nil -> :error
      ref -> {:ok, ref}
    end
  end

  # CAS-loop instead of a bare put so concurrent bumps cannot rewind
  # the counter to a lower value if their reads interleave.
  defp do_bump(ref, target) do
    current = :atomics.get(ref, 1)

    cond do
      target <= current ->
        :ok

      :atomics.compare_exchange(ref, 1, current, target) == :ok ->
        :ok

      true ->
        do_bump(ref, target)
    end
  end

  # Scans the WAL once on boot for the largest `:seq` field across all
  # decoded payloads. Returns 0 for a fresh WAL. Fails CLOSED on any
  # read failure: allocating seq 1 over a non-empty WAL reuses
  # (origin, seq) pairs already served to peers, after which this
  # node's writes silently stop replicating and the duplicates trip
  # every downstream anomaly guard.
  defp scan_for_max_seq(wal_server) do
    case safe_read_all(wal_server) do
      {:ok, entries} ->
        max_seq_in_entries(entries)

      other ->
        raise "Sealer: WAL scan failed on boot, result=#{inspect(other)} — " <>
                "refusing to allocate seq numbers over an unreadable WAL"
    end
  end

  defp safe_read_all(wal_server) do
    Locker.WAL.read_all_strict(wal_server)
  catch
    :exit, _ -> :unavailable
  end

  defp max_seq_in_entries(entries) do
    Enum.reduce(entries, 0, fn entry, acc ->
      case entry do
        %Entry{payload: %{seq: seq}} when is_integer(seq) and seq >= 0 -> max(acc, seq)
        _ -> acc
      end
    end)
  end
end
