defmodule PerpWalk.Storage.Replicator do
  @moduledoc """
  Symmetric bi-directional WAL replication.

  Every hot node accepts writes locally. Each node's local Sealer
  stamps every entry with `(:origin, :seq)` — the composite key —
  where `:origin` is this node's `Role.participant_id()` and `:seq`
  is allocated from the local atomics counter. Local seqs are
  monotonic *within an origin*; the (origin, seq) pair is globally
  unique across the federation.

  Every node runs one of these GenServers. It periodically asks
  every peer "send me your local entries past `cursor_for_you`",
  applies whatever comes back to the local WAL + domain stores,
  and advances `cursor_for_you`. The applied entries preserve
  their original `(origin, seq)` — they are NOT resealed locally,
  so the resulting WAL on each node is a converging union of all
  origins' entries.

  ## Roles per direction

  This module ships BOTH halves:

  - **Read-side (`entries_since/2`)**: a plain function any peer
    may RPC into. Verifies an HMAC-signed request, reads the local
    WAL, filters for entries with `:origin == self`, returns the
    slice past `cursor` (capped at `@max_batch_entries`) and a
    signed response.
  - **Apply-side (the GenServer)**: ticks every `@tick_interval_ms`,
    asks every configured peer for its entries past local
    `cursor[peer]`, verifies the response, appends each entry to
    the local WAL with origin preserved, dispatches to each domain
    Store's `replicate_entries/1`, and advances the cursor.

  ## Cursor

  The per-peer cursor is the highest `:seq` we have applied with
  `:origin == peer`. On boot, scanned out of the local WAL — no
  separate persistence file (the WAL itself is authoritative). On
  each tick, advanced to `max(applied entry seqs)` from the batch
  — NEVER to any cursor the responder claims. Trusting the
  responder-claimed cursor lets a compromised or buggy peer return
  an empty batch with `new_cursor: MAX` and permanently skip past
  every unseen entry (`seq > cursor` filter). The `peer_tip` field
  in the response is still read but only feeds lag telemetry, not
  cursor advancement.

  ## Test seam

  The `:rpc` opt overrides the default `:rpc.call/5` with a
  2-arity function `(node, [request]) -> response`. Tests inject a
  local function that calls `entries_since/2` directly, so the
  pipeline is exercised without a second BEAM node.

  ## Failure modes

  - Peer unreachable: `{:badrpc, _}` from `:rpc.call` is logged at
    `info`, cursor stays put, next tick retries.
  - Auth failure: `:unauthorized` / `:stale_*` / `:nonce_mismatch`
    logged at `error`, cursor stays put.
  - Apply failure: a malformed entry whose type isn't routed by
    any Store is silently skipped — same behaviour as cold-boot
    replay.
  """

  use GenServer

  require Logger

  alias Locker.WAL.Entry
  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Identity.Facade, as: IdentityFacade
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Role
  alias PerpWalk.Storage.Facade, as: StorageFacade
  alias PerpWalk.Storage.Replication.Auth
  alias PerpWalk.Storage.WAL, as: WALConfig
  alias PerpWalk.Storage.WAL.Signing
  alias PerpWalk.Telemetry.Health.System, as: HealthSystem

  @default_tick_interval_ms 1_000

  # Cap on entries returned by a single RPC. Without this, a peer
  # backfilling after a long disconnect would otherwise ship every
  # missed entry in one shot — millions buffered in memory, plus an
  # O(N) WAL scan on the responder. Capped at 1000 keeps tick-time
  # work bounded; the catch-up advances by `min(delta, 1000)` per tick.
  @max_batch_entries 1_000

  # --- Read-Side (called via :rpc.call by peers) ---

  @doc """
  Reads the local WAL entries with `:origin == self` past the
  cursor in the request, returning a signed response. Verifies the
  request HMAC + freshness before touching the WAL.

  Returns `{:ok, signed_response}` on success or `{:error, reason}`
  on auth failure or WAL unavailability.
  """
  @spec entries_since(Auth.request()) :: {:ok, Auth.response()} | {:error, term()}
  @spec entries_since(Auth.request(), GenServer.server()) ::
          {:ok, Auth.response()} | {:error, term()}
  def entries_since(request, wal_server \\ WALConfig) do
    with {:ok, cursor} <- Auth.verify_request(request),
         {:ok, entries} <- read_local_entries(wal_server) do
      my_origin = Role.participant_id()
      mine = Enum.filter(entries, &origin_match?(&1, my_origin))
      {batch, new_cursor} = slice_past_cursor(mine, cursor)
      # peer_tip is "highest seq I have to offer with origin==self" —
      # NOT the global Sealer counter. The counter reflects every
      # entry in the local WAL (including foreign-origin entries left
      # over from migrations), which inflates peer_tip and shows the
      # caller phantom lag against entries that don't belong to us.
      peer_tip = max(new_cursor, max_seq(mine))

      {:ok, Auth.sign_response(cursor, new_cursor, peer_tip, batch, request.nonce)}
    end
  end

  defp read_local_entries(wal_server) do
    # Strict read: a CRC-bad entry must fail the serve rather than be
    # silently skipped — a lenient read hands the follower a batch with
    # a permanent hole its max-applied cursor then jumps past forever.
    case Locker.WAL.read_all_strict(wal_server) do
      {:ok, _entries} = ok ->
        ok

      {:error, reason} = err ->
        Logger.error(
          "Replicator: strict WAL read failed, reason=#{inspect(reason)} — serving nothing until an operator investigates"
        )

        :telemetry.execute(
          [:perp_walk, :storage, :replicator, :serve_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        err
    end
  catch
    :exit, reason ->
      Logger.error("Replicator: WAL read exited, reason=#{inspect(reason)}")

      :telemetry.execute(
        [:perp_walk, :storage, :replicator, :serve_failed],
        %{count: 1},
        %{reason: inspect(reason)}
      )

      {:error, :wal_unavailable}
  end

  defp origin_match?(%Entry{payload: %{origin: o}}, expected) when o == expected, do: true
  defp origin_match?(_, _), do: false

  defp max_seq(entries) do
    Enum.reduce(entries, 0, fn
      %Entry{payload: %{seq: s}}, acc when is_integer(s) -> max(acc, s)
      _, acc -> acc
    end)
  end

  defp slice_past_cursor(entries, cursor) do
    Enum.reduce(entries, {[], cursor}, fn entry, {acc, hw} ->
      case entry do
        %Entry{payload: %{seq: seq}} when is_integer(seq) and seq > cursor ->
          if length(acc) >= @max_batch_entries do
            {acc, hw}
          else
            {[entry | acc], max(hw, seq)}
          end

        _ ->
          {acc, hw}
      end
    end)
    |> then(fn {acc, hw} -> {Enum.reverse(acc), hw} end)
  end

  # --- Apply-Side Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Snapshot of cursors per peer. Read-only — used by Console + dashboards."
  @spec status(GenServer.server()) :: %{atom() => map()}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Test seam: triggers a single replication tick synchronously."
  @spec tick_now(GenServer.server()) :: :ok
  def tick_now(server \\ __MODULE__), do: GenServer.call(server, :tick_now)

  # --- GenServer ---

  @impl true
  def init(opts) do
    peers = Keyword.get(opts, :peers, [])
    rpc = Keyword.get(opts, :rpc, &:rpc.call/5)
    wal_server = Keyword.get(opts, :wal_server, WALConfig)
    tick_interval_ms = Keyword.get(opts, :tick_interval_ms, @default_tick_interval_ms)
    auto_tick = Keyword.get(opts, :auto_tick, true)

    cursors = build_initial_cursors(peers, wal_server)

    if auto_tick and peers != [] do
      schedule_tick(tick_interval_ms)
    end

    {:ok,
     %{
       peers: peers,
       cursors: cursors,
       rpc: rpc,
       wal_server: wal_server,
       tick_interval_ms: tick_interval_ms,
       auto_tick: auto_tick,
       peer_tips: %{}
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    snapshot =
      Map.new(state.peers, fn peer ->
        {peer.origin,
         %{
           node: peer.node,
           cursor: Map.get(state.cursors, peer.origin, 0),
           peer_tip: Map.get(state.peer_tips, peer.origin, 0)
         }}
      end)

    {:reply, snapshot, state}
  end

  def handle_call(:tick_now, _from, state) do
    new_state = run_tick(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state = run_tick(state)
    if state.auto_tick, do: schedule_tick(new_state.tick_interval_ms)
    {:noreply, new_state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- Tick ---

  defp run_tick(state) do
    Enum.reduce(state.peers, state, fn peer, acc -> pull_from_peer(peer, acc) end)
  end

  defp pull_from_peer(peer, state) do
    cursor = Map.get(state.cursors, peer.origin, 0)
    request = Auth.sign_request(cursor)

    case do_rpc(state.rpc, peer.node, request) do
      {:ok, response} ->
        handle_response(peer, response, request, state)

      {:badrpc, reason} ->
        Logger.info("Replicator: peer #{peer.origin} unreachable, reason=#{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.warning("Replicator: peer #{peer.origin} error, reason=#{inspect(reason)}")
        state

      other ->
        Logger.warning("Replicator: peer #{peer.origin} unexpected reply, reply=#{inspect(other)}")

        state
    end
  end

  defp do_rpc(rpc, node, request) when is_function(rpc, 5) do
    rpc.(node, __MODULE__, :entries_since, [request], 5_000)
  end

  defp do_rpc(rpc, node, request) when is_function(rpc, 2) do
    rpc.(node, [request])
  end

  defp handle_response(peer, response, request, state) do
    case Auth.verify_response(response, request.cursor, request.nonce) do
      {:ok, entries, _responder_cursor, peer_tip} ->
        with :ok <- verify_seq_contiguity(entries, request.cursor, peer.origin),
             :ok <- verify_signatures(entries, peer.origin),
             # Apply INSIDE the guard chain — the cursor must not
             # advance past a batch that failed to land.
             :ok <- apply_entries(entries, state.wal_server) do
          # Cursor advances ONLY to the max seq we actually applied,
          # NEVER to the responder's claimed `new_cursor`. Trusting
          # the responder-claimed cursor lets a malicious (or buggy)
          # peer return an empty batch with `new_cursor` jumped past
          # real entries — the follower would skip past them
          # forever on subsequent requests (`seq > cursor`).
          new_cursor = advance_cursor(request.cursor, entries)

          # Auto-clear the replicator source-halt on any successful
          # verified apply. Without this, the halt entry sticks in the
          # source-halts ETS table forever after a transient rejection
          # (e.g. one bad batch during a peer misconfiguration window),
          # forcing operator intervention to un-halt even after the
          # underlying condition self-resolves. Idempotent — clearing
          # an already-clear source is a no-op.
          maybe_clear_replicator_halt()

          Logger.debug(
            "Replicator: applied batch, peer=#{peer.origin}, count=#{length(entries)}, " <>
              "new_cursor=#{new_cursor}, peer_tip=#{peer_tip}"
          )

          # Per-peer tick telemetry feeds `Telemetry.Health.Cache`
          # which the `:peer_replication_lagging` alert rules read via
          # `max_lag/0`. Emitted only on a successful apply — auth
          # failures take the `:batch_rejected` event below.
          :telemetry.execute(
            [:perp_walk, :storage, :replicator, :tick],
            %{
              cursor: new_cursor,
              peer_tip: peer_tip,
              lag: max(peer_tip - new_cursor, 0),
              batch_size: length(entries)
            },
            %{peer: peer.origin, result: :ok}
          )

          %{
            state
            | cursors: Map.put(state.cursors, peer.origin, new_cursor),
              peer_tips: Map.put(state.peer_tips, peer.origin, peer_tip)
          }
        else
          {:error, {failure_kind, detail}} when failure_kind in [:apply_failed, :append_failed] ->
            # Domain dispatch or local append failed — the batch was
            # never durably applied, the cursor holds, and the next
            # tick retries. Halt new writes (auto-clearing) until a
            # clean batch lands: our business state is stalled behind
            # the leader's and every liability written now diverges.
            Logger.error("Replicator: #{failure_kind}, peer=#{peer.origin}, detail=#{detail}")

            HealthSystem.set_source_halt(
              :replicator,
              "replication #{failure_kind} from #{inspect(peer.origin)}: #{detail}"
            )

            :telemetry.execute(
              [:perp_walk, :storage, :replicator, :batch_rejected],
              %{count: 1},
              %{peer: peer.origin, reason: {failure_kind, detail}}
            )

            state

          {:error, reason} ->
            halt_on_signature_failure(peer, reason)

            :telemetry.execute(
              [:perp_walk, :storage, :replicator, :batch_rejected],
              %{count: 1},
              %{peer: peer.origin, reason: reason}
            )

            state
        end

      {:error, reason} ->
        Logger.error("Replicator: response rejected, peer=#{peer.origin}, reason=#{inspect(reason)}")

        # Emit telemetry so the `:replication_batch_rejected` alert
        # rule can observe and fire. Log-only is insufficient — the
        # rule sweeps the `Telemetry.Health.Cache` which is fed by
        # this telemetry event, not by log messages.
        :telemetry.execute(
          [:perp_walk, :storage, :replicator, :batch_rejected],
          %{count: 1},
          %{peer: peer.origin, reason: reason}
        )

        state
    end
  end

  defp advance_cursor(current, []), do: current

  defp advance_cursor(current, entries) do
    Enum.reduce(entries, current, fn %Entry{payload: %{seq: s}}, acc -> max(acc, s) end)
  end

  # `Sealer.next_seq/0` is a NODE-wide counter, not per-origin: it
  # allocates the next seq across every entry the node writes,
  # including replicated-in entries from peers (via `bump_to/1`).
  # So origin=X's own entries have monotonically-increasing seqs but
  # NOT contiguous ones — a peer that also replicates entries from
  # other origins will interleave seqs. Example: s3 boots, receives
  # s1's seqs 1..3 (bumping local counter to 3), then writes its first
  # own entry at seq=4. From s1's perspective, s3's cursor is 0 and
  # the first batch it receives starts at seq=4, not seq=1.
  #
  # The invariants we actually want:
  #   1. First entry's seq > receiver's cursor (no rewind).
  #   2. Each subsequent entry's seq > the previous one's (monotonic).
  # Signature verification handles authenticity separately.
  defp verify_seq_contiguity([], _cursor, _origin), do: :ok

  defp verify_seq_contiguity(entries, cursor, origin) do
    entries
    |> Enum.reduce_while({:ok, cursor}, fn %Entry{payload: %{seq: seq}}, {:ok, last} ->
      if seq > last do
        {:cont, {:ok, seq}}
      else
        {:halt, {:error, {:seq_non_monotonic, origin, last, seq}}}
      end
    end)
    |> case do
      {:ok, _last} -> :ok
      {:error, _} = err -> err
    end
  end

  # Verify every entry: signature valid, origin matches the peer we
  # asked. A single failure fails the batch — partial apply would
  # leave the WAL in an ambiguous half-authenticated state on future
  # replay.
  defp verify_signatures(entries, expected_origin) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      if entry_origin_matches?(entry, expected_origin) do
        case Signing.verify_entry(entry) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {reason, entry_origin(entry), entry.type}}}
        end
      else
        {:halt, {:error, {:origin_mismatch, entry_origin(entry)}}}
      end
    end)
  end

  defp entry_origin_matches?(%Entry{payload: %{origin: o}}, expected) when o == expected, do: true
  defp entry_origin_matches?(_, _), do: false

  defp entry_origin(%Entry{payload: %{origin: o}}) when is_atom(o), do: o
  defp entry_origin(_), do: :unknown

  # Signature-failure halts use a distinct STICKY source key
  # (`:replicator_signature`) that is NEVER auto-cleared by
  # subsequent good batches. A signature failure indicates active
  # peer compromise or key mismatch — not a transient network
  # condition — and a mostly-honest malicious peer that sends one
  # bad batch followed by many good ones would previously reset
  # the halt on the very next batch. Operator must investigate the
  # root cause (pinning drift, actual compromise) and clear via
  # `Federation.Console` explicitly.
  defp halt_on_signature_failure(peer, reason) do
    Logger.error("Replicator: signature verification failed, peer=#{peer.origin}, reason=#{inspect(reason)}")

    HealthSystem.set_source_halt(
      :replicator_signature,
      "replication signature failure from #{inspect(peer.origin)}: #{inspect(reason)}"
    )
  end

  # Log + clear only on the halted→healthy transition of the
  # AUTO-CLEARABLE source slot. The sticky `:replicator_signature`
  # slot is intentionally excluded — it survives good batches until
  # an operator clears it.
  defp maybe_clear_replicator_halt do
    if Map.has_key?(HealthSystem.source_halts(), :replicator) do
      Logger.info("Replicator: source-halt cleared after successful batch apply")
      HealthSystem.clear_source_halt(:replicator)
    end
  end

  # --- Apply ---

  defp apply_entries([], _wal_server), do: :ok

  defp apply_entries(entries, wal_server) do
    # Dispatch to domain stores BEFORE appending locally. Domain apply
    # raises on a malformed-but-authenticated entry (schema drift, a
    # poisoned peer), and an entry that crashes dispatch must never
    # become durable — boot replay would hit it on every start and
    # brick the node. Domain applies are idempotent upserts, so a
    # post-dispatch append failure safely retries the whole batch on
    # the next tick.
    with :ok <- dispatch_entries(entries),
         :ok <- append_entries(entries, wal_server) do
      max_applied = max_seq(entries)
      if max_applied > 0, do: StorageFacade.bump_wal_seq(max_applied)
      :ok
    end
  end

  defp dispatch_entries(entries) do
    with :ok <- safe_replicate(FederationFacade, :federation, entries),
         :ok <- safe_replicate(MarketsFacade, :markets, entries) do
      safe_replicate(IdentityFacade, :identity, entries)
    end
  end

  # A dispatch/append failure must never crash the Replicator process:
  # crashing under rest_for_one flaps the endpoints and can exhaust
  # the root restart budget during exactly the degraded windows (disk
  # full, store restart) that produce these failures. Return an error
  # instead — the cursor holds and the next tick retries.
  defp safe_replicate(facade, domain, entries) do
    facade.replicate_entries(entries)
  rescue
    e ->
      Logger.error("Replicator: domain apply raised, domain=#{domain}, reason=#{inspect(e)}")
      {:error, {:apply_failed, "#{domain}: #{inspect(e)}"}}
  catch
    :exit, reason ->
      Logger.error("Replicator: domain apply exited, domain=#{domain}, reason=#{inspect(reason)}")
      {:error, {:apply_failed, "#{domain}: #{inspect(reason)}"}}
  end

  defp append_entries(entries, wal_server) do
    Enum.each(entries, fn entry ->
      :ok = Locker.WAL.append(wal_server, entry)
    end)

    :ok
  rescue
    e ->
      Logger.error("Replicator: local WAL append failed, reason=#{inspect(e)}")
      {:error, {:append_failed, inspect(e)}}
  end

  # --- Boot Cursor Recovery ---

  defp build_initial_cursors(peers, wal_server) do
    case Locker.WAL.read_all(wal_server) do
      {:ok, entries} -> max_seq_by_origin(entries) |> seed_for_peers(peers)
      _ -> seed_for_peers(%{}, peers)
    end
  catch
    :exit, _ -> seed_for_peers(%{}, peers)
  end

  defp max_seq_by_origin(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      case entry do
        %Entry{payload: %{origin: o, seq: s}} when is_atom(o) and is_integer(s) ->
          Map.update(acc, o, s, &max(&1, s))

        _ ->
          acc
      end
    end)
  end

  defp seed_for_peers(by_origin, peers) do
    Map.new(peers, fn peer -> {peer.origin, Map.get(by_origin, peer.origin, 0)} end)
  end

  # --- Misc ---

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end
end
