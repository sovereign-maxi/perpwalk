defmodule PerpWalk.Identity.Sessions do
  @moduledoc """
  Server-side registry of active web sessions.

  Phoenix signed-cookie sessions are stateless — the server trusts
  any cookie that carries a valid signature, regardless of whether
  the user has "logged out" client-side. That means a stolen cookie
  stays useful until the cookie max_age expires.

  This module gates every request behind a server-side lookup. The
  cookie now carries an opaque `session_id` (32 random bytes, base64
  encoded) instead of the raw `account_id`. On login we mint a fresh
  session_id and store the mapping. On logout we delete it. Every
  subsequent request to `PerpWalkWeb.Auth.fetch_current_account/2`
  consults the store; if the session_id has been revoked, the
  request is treated as anonymous even though the cookie is
  cryptographically valid.

  ## Storage

  In-memory ETS only — sessions don't survive a Phoenix restart.
  That's a deliberate tradeoff: it forces re-login after a deploy,
  but keeps the implementation simple and avoids leaking session
  metadata to disk. For multi-node deployments or rolling restarts,
  back this with the WAL + a periodic snapshot.

  ## Threat model

  - Cookie theft (XSS, network capture, malware): mitigated.
    Logout invalidates the session_id server-side, so a captured
    cookie stops working the moment the legit user logs out.
  - Server-side replay after logout: blocked.
  - Brute-force session_id: 32 bytes of `:crypto.strong_rand_bytes`
    is 256 bits of entropy. Not feasible to guess.
  - Side-channel timing on session_id lookup: ETS lookup is O(1)
    on a `:set` and the worst case is "not found" — same code path
    as a found-but-revoked entry. We don't differentiate.
  """

  use GenServer

  require Logger

  alias Locker.WAL.Entry
  alias PerpWalk.Storage.Facade, as: StorageFacade
  alias PerpWalk.Storage.WAL.Replay

  # Two tables, split by sensitivity. The session_id → account_id
  # binding can live in a `:public` table because account_ids are
  # already in cookies and URLs — there's no in-VM secret leak from
  # `:ets.tab2list/1`. The per-venue Nostr seckey is different: it's
  # 32 bytes of secp256k1 key material that gates comment signing,
  # so it lives in a separate `:private` table that only this
  # GenServer can read or write. Even a process that knows the
  # table name can't enumerate it; the access mode is BEAM-enforced.
  @table __MODULE__
  @secrets_table __MODULE__.Secrets
  @session_id_bytes 32

  # Shared application WAL. Session create/revoke entries AND the
  # per-session seckey binding are persisted here so a Phoenix
  # restart (deploy) doesn't log every active user out or break
  # comment signing. The original "seckey never on disk" stance was
  # treating cold-seizure memory-only as load-bearing, but /data is
  # encrypted at rest and the federation's master signing key already lives
  # on the same volume — adding 32 bytes of per-user seckey changes
  # the seizure scenario only cosmetically.
  @wal_server PerpWalk.Storage.WAL

  # Sessions older than this are dropped on the next sweep tick.
  # 30 days matches the operator's "treat the venue like cash in
  # your pocket" framing — long enough that frequent users don't
  # hit it, short enough that an abandoned tab doesn't carry an
  # authenticated cookie indefinitely.
  @max_age_ms 30 * 24 * 60 * 60 * 1_000
  @sweep_interval_ms 60 * 60 * 1_000

  # Cap on active sessions per account_id. Each Tor circuit rotation
  # bypasses the cookie-bound revoke at log_in, so a hostile actor
  # holding a keyphrase can otherwise mint unbounded session rows.
  # On the (N+1)th login we revoke the oldest existing session for
  # that account; the user keeps N rolling. Real humans don't hit
  # this — a phone + laptop + browser-on-tablet = 3, well under cap.
  @max_sessions_per_account 20

  @typedoc "Opaque session identifier. Base64-encoded random bytes."
  @type session_id :: binary()

  @doc """
  PubSub topic on which `:session_revoked` is broadcast when a
  given `session_id` is revoked. LiveView mounts subscribe to this
  topic and self-redirect on receipt, so a "log out everywhere"
  flow tears down sockets that were already connected when the
  revoke happened.
  """
  @spec topic(session_id()) :: String.t()
  def topic(session_id) when is_binary(session_id), do: "session:" <> session_id

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Mints a fresh session_id, binds it to `account_id`, and returns
  the new id. The id is opaque to the caller — store it in the
  Phoenix session cookie under `:session_id`.

  ## Options

  - `:nostr_seckey` (32-byte binary) — the per-venue Nostr secret
    key derived from the user's keyphrase at login. Persisted via
    the same WAL the session row is persisted in, so a deploy
    doesn't break comment signing. Cleared on `revoke/1` and
    `revoke_all_for_account/1`. Retrieved via
    `lookup_nostr_seckey/1` for the comment signing path.
  """
  @spec create(binary(), keyword()) :: session_id()
  def create(account_id, opts \\ []) when is_binary(account_id) do
    session_id = :crypto.strong_rand_bytes(@session_id_bytes) |> Base.url_encode64(padding: false)
    nostr_seckey = Keyword.get(opts, :nostr_seckey)
    created_at_ms = System.system_time(:millisecond)
    # Monotonic per-BEAM insertion sequence. `created_at_ms` alone
    # can't be the sort key for cap eviction: sub-millisecond bursts
    # (login flood, tests) produce identical timestamps and ETS
    # iteration order for :set is hash order, not insert order — so
    # ties get resolved arbitrarily. `insert_seq` is strictly
    # increasing per call, so sort by it and the OLDEST always wins.
    insert_seq = :erlang.unique_integer([:monotonic, :positive])

    enforce_per_account_cap_serialized(account_id)

    # Persist the (sid, account_id, created_at, insert_seq) tuple via
    # the shared WAL before populating ETS so that a Phoenix restart
    # can replay the session back into the ETS table on boot. Append
    # is best-effort — if it fails (WAL down, follower) the ETS write
    # still happens and the session works for this BEAM lifetime.
    persist_session_created(session_id, account_id, created_at_ms, insert_seq)
    :ets.insert(@table, {session_id, account_id, created_at_ms, insert_seq})

    # The seckey table is `:private` — only the GenServer can write
    # to it. Fall back to in-table-only if the server isn't running
    # (test isolation / early boot) so the session itself still
    # mints and the user just won't have signing-capable state.
    # WAL-persisted alongside the session row so deploys don't break
    # comment signing: the session and the seckey share a lifetime
    # and both replay from the WAL on restart. The original "never
    # persist seckey" stance treated cold-seizure memory-only as
    # load-bearing, but /data is encrypted at rest, the federation's master
    # signing key is already on disk for service restart, and the
    # comment + account_id linkage is already in the WAL — adding
    # 32 bytes of per-user seckey to the same encrypted volume
    # changes the seizure scenario only cosmetically.
    if is_binary(nostr_seckey) do
      safe_put_seckey(session_id, nostr_seckey)
      persist_seckey_bound(session_id, nostr_seckey)
    end

    session_id
  end

  # The cap is enforced inside the GenServer when it's running so
  # concurrent logins for one account can't both pass a caller-side
  # check-then-act. Direct only as a pre-supervisor boot fallback.
  defp enforce_per_account_cap_serialized(account_id) do
    case GenServer.whereis(__MODULE__) do
      nil -> enforce_per_account_cap(account_id)
      _pid -> GenServer.call(__MODULE__, {:enforce_cap, account_id})
    end
  end

  defp safe_put_seckey(session_id, seckey) do
    GenServer.call(__MODULE__, {:put_seckey, session_id, seckey})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Looks up `session_id` and returns its bound account.

  Returns `{:ok, account_id}` for a live session, `{:error, :not_found}`
  if the session was never minted, was revoked, or the table doesn't
  exist (e.g., during pre-supervisor startup).
  """
  @spec lookup(session_id()) :: {:ok, binary()} | {:error, :not_found}
  def lookup(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, account_id, created_at_ms, _insert_seq}] ->
        if System.system_time(:millisecond) - created_at_ms <= @max_age_ms do
          {:ok, account_id}
        else
          # The hourly sweep will eventually catch this row, but the
          # lookup-time check closes the up-to-an-hour window where a
          # past-TTL session could still authenticate.
          :ets.delete(@table, session_id)
          {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  def lookup(_), do: {:error, :not_found}

  @doc """
  Returns the per-venue Nostr secret key bound to `session_id`, or
  `{:error, :not_found}` if no session exists or the session
  predates the Nostr-key field. The session's TTL still applies —
  past-TTL sessions are treated as `:not_found` here too.

  The seckey is a 32-byte binary, exclusive to this venue (HKDF
  derivation in `Account.derive_nostr_keypair/1`). Persisted via
  the same WAL as the session row so deploys don't break comment
  signing; cleared on revoke (and on TTL sweep, both surfaces).
  """
  @spec lookup_nostr_seckey(session_id()) ::
          {:ok, binary()} | {:error, :not_found | :no_nostr_key}
  def lookup_nostr_seckey(session_id) when is_binary(session_id) do
    # The secrets table is `:private`, so reads route through the
    # owning GenServer. Public-table TTL is checked here first so
    # an expired session never reaches the seckey lookup.
    case :ets.lookup(@table, session_id) do
      [{^session_id, _account_id, created_at_ms, _insert_seq}] ->
        if System.system_time(:millisecond) - created_at_ms > @max_age_ms do
          :ets.delete(@table, session_id)
          # Cast — owner deletes from the secrets table on its own.
          GenServer.cast(__MODULE__, {:drop_seckey, session_id})
          {:error, :not_found}
        else
          GenServer.call(__MODULE__, {:lookup_seckey, session_id})
        end

      [] ->
        {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  def lookup_nostr_seckey(_), do: {:error, :not_found}

  @doc "Revokes a single session_id. Idempotent — silent for unknown ids."
  @spec revoke(session_id()) :: :ok
  def revoke(session_id) when is_binary(session_id) do
    persist_session_revoked(session_id)
    :ets.delete(@table, session_id)
    GenServer.cast(__MODULE__, {:drop_seckey, session_id})
    broadcast_revoke(session_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def revoke(_), do: :ok

  @doc """
  Revokes every session_id currently bound to `account_id`. Useful
  for "log me out everywhere" flows or when an account is rotated.
  Returns the count of sessions removed.

  Broadcasts a `:session_revoked` message for each session removed
  so LiveView sockets that were mounted before the revoke tear
  themselves down (see `topic/1`). Without this, a logged-in
  socket keeps `current_account_id` assigned until its WebSocket
  closes — so "log me out everywhere" would block new requests
  but leave already-connected views accepting events.
  """
  @spec revoke_all_for_account(binary()) :: non_neg_integer()
  def revoke_all_for_account(account_id) when is_binary(account_id) do
    pattern = {:"$1", account_id, :_, :_}
    matches = :ets.match(@table, pattern)

    Enum.each(matches, fn [sid] ->
      persist_session_revoked(sid)
      :ets.delete(@table, sid)
      GenServer.cast(__MODULE__, {:drop_seckey, sid})
      broadcast_revoke(sid)
    end)

    length(matches)
  rescue
    ArgumentError -> 0
  end

  # Enforces `@max_sessions_per_account` by revoking the oldest
  # outstanding sessions for `account_id` until at most
  # `@max_sessions_per_account - 1` remain (leaving room for the
  # fresh session the caller is about to insert). Each revocation
  # goes through the public `revoke/1` so the WAL entry + PubSub
  # broadcast fire — the auth.ex revoke listener picks them up and
  # tears down any LiveView sockets still mounted under the
  # revoked sid.
  defp enforce_per_account_cap(account_id) do
    # Sort by insert_seq (4th element), not created_at_ms — see the
    # comment in `create/2` for why.
    pattern = {:"$1", account_id, :_, :"$2"}

    existing =
      @table
      |> :ets.match(pattern)
      |> Enum.sort_by(fn [_sid, insert_seq] -> insert_seq end)

    overflow = length(existing) - (@max_sessions_per_account - 1)

    if overflow > 0 do
      existing
      |> Enum.take(overflow)
      |> Enum.each(fn [sid, _insert_seq] -> revoke(sid) end)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # Broadcast failures are non-fatal: the revoke itself has already
  # landed in ETS, so any subsequent HTTP request is anonymous. The
  # broadcast is purely about tearing down sockets that bypass the
  # HTTP gate. If PubSub isn't running (early boot, test isolation),
  # swallow the error rather than crash the caller.
  defp broadcast_revoke(session_id) do
    Phoenix.PubSub.broadcast(PerpWalk.PubSub, topic(session_id), {:session_revoked, session_id})
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # --- WAL Persistence ---
  #
  # The persist_* helpers are no-ops on followers (writes_allowed?
  # returns false) and tolerate WAL absence when the WAL server
  # isn't running (the rescue catches "WAL server not started" /
  # "process not alive" cases).
  # The ETS write happens regardless so behaviour for the current
  # BEAM lifetime is identical to the pre-WAL version even if
  # persistence fails — the only loss is restart durability.

  defp persist_session_created(session_id, account_id, created_at_ms, insert_seq) do
    append_wal(:session_created, %{
      sid: session_id,
      account_id: account_id,
      created_at_ms: created_at_ms,
      insert_seq: insert_seq
    })
  end

  defp persist_session_revoked(session_id) do
    append_wal(:session_revoked, %{sid: session_id})
  end

  defp persist_seckey_bound(session_id, seckey) do
    append_wal(:session_seckey_bound, %{sid: session_id, seckey: seckey})
  end

  # Goes through `Storage.Facade.seal_and_append/3` so every session
  # entry carries a `:seq` field. Without this, the follower-side
  # Replicator validator would halt on session entries (no seq) and
  # wedge replication — every tick re-fetching the same batch with
  # the seqless session entry, never advancing the cursor. The seq
  # comes from the global atomics counter so monotonicity holds
  # across all WAL types.
  defp append_wal(type, payload) do
    StorageFacade.seal_and_append(type, payload, @wal_server)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # --- Follower Replication ---

  @doc """
  Applies session entries from the leader's WAL to local ETS. Called
  by `Storage.Replicator` via `Identity.Facade.replicate_entries/1`.

  Only acts on `:session_created` / `:session_revoked` /
  `:session_seckey_bound` entries — silently skips everything else
  so the same entry list can be passed to every domain's
  replicate_entries/1.

  Refused on the leader; the leader writes via the regular `create`/
  `revoke` API and would corrupt its own state if it also replicated
  from itself.
  """
  # Session WAL types this store owns. Entries with foreign types
  # pass through the catch-all silently; entries with owned types
  # but unrecognised payload shape trigger `halt_on_malformed/2`.
  @owned_wal_types MapSet.new([:session_created, :session_revoked, :session_seckey_bound])

  @spec replicate_entries([Entry.t()]) :: :ok
  def replicate_entries(entries) when is_list(entries) do
    Replay.each_or_halt(entries, :identity_sessions, &apply_replicated_entry/1)
  end

  defp apply_replicated_entry(%Entry{type: :session_created, payload: %{sid: sid} = p}) do
    account_id = Map.get(p, :account_id)
    created_at_ms = Map.get(p, :created_at_ms, System.system_time(:millisecond))
    # Older WAL entries have no `insert_seq`; synthesise a monotonic
    # value at apply time. Because `:erlang.unique_integer` is
    # strictly increasing per BEAM, applied-in-order entries end up
    # with correct relative ordering even without the persisted seq.
    insert_seq = Map.get(p, :insert_seq, :erlang.unique_integer([:monotonic, :positive]))

    if is_binary(account_id) and is_binary(sid) do
      ensure_table_exists()
      :ets.insert(@table, {sid, account_id, created_at_ms, insert_seq})
    end
  end

  defp apply_replicated_entry(%Entry{type: :session_revoked, payload: %{sid: sid}})
       when is_binary(sid) do
    ensure_table_exists()
    :ets.delete(@table, sid)
    # Cast — the Sessions GenServer owns the `:private` secrets
    # table, so the secrets-table delete has to route through it.
    GenServer.cast(__MODULE__, {:drop_seckey, sid})
  end

  # Routes the seckey write through the Sessions GenServer because
  # the secrets table is `:private` and only the owning process can
  # write to it. Synchronous to keep replication semantics tight —
  # the leader has already committed; the follower converges.
  defp apply_replicated_entry(%Entry{
         type: :session_seckey_bound,
         payload: %{sid: sid, seckey: seckey}
       })
       when is_binary(sid) and is_binary(seckey) do
    GenServer.call(__MODULE__, {:put_seckey, sid, seckey})
  catch
    :exit, _ -> :ok
  end

  # Owned type + shape mismatch = halt; foreign type = silent skip.
  defp apply_replicated_entry(%Entry{type: type} = entry) do
    if MapSet.member?(@owned_wal_types, type) do
      Replay.halt_on_malformed(:identity_sessions, entry)
    else
      :ok
    end
  end

  defp ensure_table_exists do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

      _ ->
        :ok
    end
  end

  @doc "Returns the count of active sessions. Useful for ops dashboards."
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size) || 0
  rescue
    ArgumentError -> 0
  end

  @doc """
  Returns the underlying ETS table name. Exposed for test
  helpers that need to wipe state between cases — production
  code should use `revoke/1` or `revoke_all_for_account/1` and
  never touch the table directly.
  """
  @spec table_name() :: atom()
  def table_name, do: @table

  # --- GenServer ---

  @impl true
  def init(_opts) do
    create_tables()
    replay_wal()
    schedule_sweep()
    {:ok, %{}}
  end

  # Replays session_created / session_revoked entries from the shared
  # WAL into local ETS. Expired entries are filtered at replay time so
  # the table doesn't briefly hold past-TTL sessions between init and
  # the first sweep.
  #
  # Failure posture: a missing WAL server (pre-supervisor boot) is
  # tolerated — the table starts empty. A WAL that exists but FAILS
  # a strict read is not: booting with an empty session table when
  # disk holds revoked-session entries would resurrect logged-out
  # sessions, so boot raises unless the operator explicitly sets
  # halt_on_corrupt: false. Each applied entry also passes the
  # shared boot authenticity gate.
  defp replay_wal do
    cutoff = System.system_time(:millisecond) - @max_age_ms

    case safe_read_all() do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          unless boot_gate_halt?(entry) do
            apply_replay_entry(entry, cutoff)
          end
        end)

      :unavailable ->
        :ok
    end
  end

  defp safe_read_all do
    Locker.WAL.read_all_strict(@wal_server)
  catch
    # WAL server not running (pre-supervisor boot).
    :exit, _ -> :unavailable
  else
    {:ok, entries} ->
      {:ok, entries}

    {:error, reason} ->
      if halt_on_corrupt?() do
        raise "Identity.Sessions: boot replay could not strictly read the WAL, " <>
                "reason=#{inspect(reason)} — starting with an empty session table " <>
                "would resurrect revoked sessions. Investigate the WAL before " <>
                "forcing skip via :perpwalk, :wal, halt_on_corrupt: false."
      else
        Logger.warning("Sessions: WAL strict read failed (#{inspect(reason)}), starting empty")
        :unavailable
      end
  end

  # Boot-time authenticity gate, mirroring the markets/federation
  # replay paths. Only session-owned types are gated — foreign types
  # belong to other domains' replays, which gate their own.
  defp boot_gate_halt?(%Entry{type: type} = entry) do
    if MapSet.member?(@owned_wal_types, type) and
         Replay.halt_entry?(entry, :identity_sessions) do
      if halt_on_corrupt?() do
        raise "Identity.Sessions: boot replay refused entry, type=#{inspect(type)} — " <>
                "signature/origin invalid for the current signing mode. " <>
                "Investigate the WAL before forcing skip via :perpwalk, :wal, halt_on_corrupt: false."
      else
        Logger.warning("Sessions: skipping entry with invalid signature/origin, type=#{inspect(type)}")
        true
      end
    else
      false
    end
  end

  defp halt_on_corrupt? do
    Application.get_env(:perpwalk, :wal, [])
    |> Keyword.get(:halt_on_corrupt, true)
  end

  defp apply_replay_entry(%Entry{type: :session_created, payload: %{sid: sid} = p}, cutoff) do
    account_id = Map.get(p, :account_id)
    created_at_ms = Map.get(p, :created_at_ms, 0)
    insert_seq = Map.get(p, :insert_seq, :erlang.unique_integer([:monotonic, :positive]))

    if is_binary(sid) and is_binary(account_id) and created_at_ms >= cutoff do
      :ets.insert(@table, {sid, account_id, created_at_ms, insert_seq})
    end
  end

  defp apply_replay_entry(%Entry{type: :session_revoked, payload: %{sid: sid}}, _cutoff)
       when is_binary(sid) do
    :ets.delete(@table, sid)
    :ets.delete(@secrets_table, sid)
  end

  # Replay runs inside the Sessions GenServer's init/1, so a direct
  # write into the `:private` secrets table is safe — we ARE the
  # owner. The replicated-path equivalent in `apply_replicated_entry/1`
  # has to route through a GenServer call instead.
  defp apply_replay_entry(
         %Entry{type: :session_seckey_bound, payload: %{sid: sid, seckey: seckey}},
         cutoff
       )
       when is_binary(sid) and is_binary(seckey) do
    case :ets.lookup(@table, sid) do
      [{^sid, _account_id, created_at_ms, _insert_seq}] when created_at_ms >= cutoff ->
        :ets.insert(@secrets_table, {sid, seckey})

      _ ->
        :ok
    end
  end

  defp apply_replay_entry(_, _), do: :ok

  @impl true
  def handle_call({:put_seckey, session_id, seckey}, _from, state) do
    :ets.insert(@secrets_table, {session_id, seckey})
    {:reply, :ok, state}
  end

  def handle_call({:lookup_seckey, session_id}, _from, state) do
    reply =
      case :ets.lookup(@secrets_table, session_id) do
        [{^session_id, seckey}] when is_binary(seckey) -> {:ok, seckey}
        _ -> {:error, :no_nostr_key}
      end

    {:reply, reply, state}
  end

  # Serialized per-account cap enforcement for `create/2`. Running
  # the check-then-act inside the GenServer closes the race where
  # two concurrent logins for one account both pass a caller-side
  # count check and exceed the cap. `enforce_per_account_cap/1`
  # only casts back here (drop_seckey), so no self-deadlock.
  def handle_call({:enforce_cap, account_id}, _from, state) do
    {:reply, enforce_per_account_cap(account_id), state}
  end

  @impl true
  def handle_cast({:drop_seckey, session_id}, state) do
    :ets.delete(@secrets_table, session_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.system_time(:millisecond) - @max_age_ms

    # match_delete pattern matches sessions whose created_at_ms is
    # older than the cutoff. The third tuple element is the timestamp;
    # the fourth (insert_seq) is unused by the sweep.
    spec = [{{:"$1", :_, :"$2", :_}, [{:<, :"$2", cutoff}], [:"$1"]}]
    expired_ids = :ets.select(@table, spec)

    Enum.each(expired_ids, fn sid ->
      :ets.delete(@table, sid)
      :ets.delete(@secrets_table, sid)
      # A socket mounted under a swept sid otherwise stays
      # authenticated until its WebSocket closes — the TTL must
      # tear it down the same way an explicit revoke does.
      broadcast_revoke(sid)
    end)

    removed = length(expired_ids)
    if removed > 0, do: Logger.info("Sessions: swept expired sessions, count=#{removed}")

    schedule_sweep()
    {:noreply, state}
  rescue
    ArgumentError ->
      schedule_sweep()
      {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp create_tables do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

      _ref ->
        @table
    end

    case :ets.whereis(@secrets_table) do
      :undefined ->
        :ets.new(@secrets_table, [:named_table, :set, :private])

      _ref ->
        @secrets_table
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
