defmodule PerpWalk.Federation.Checkpointer do
  @moduledoc """
  Periodic Ed25519-signed state root of the venue.

  Each guardian ticks every `:cadence_ms` (default 15 min) and:

  1. Captures the current reserves snapshot via
     `Reserves.Facade.capture_snapshot/0` and converts to piconero
     shape.
  2. Reads the current WAL cursor via `Storage.WAL.Sealer.current_seq/0`.
  3. Computes a 32-byte state root over snapshot + cursor via
     `Checkpointer.Digest.compute/2`.
  4. Signs the state root with the local guardian's Ed25519 key via
     `Federation.Keys.sign/1`.
  5. Seals `:checkpoint_completed` to the WAL carrying the snapshot
     fields, cursor, participant id, signature, and pubkey.
  6. Publishes a NIP-33 kind-30081 Nostr event signed by the local
     guardian's venue Nostr identity, embedding the Ed25519
     signature over the state root as an inner attestation.

  Two signatures, two purposes: inner Ed25519 over the state root
  for state integrity, outer venue Nostr for distribution
  authentication.

  ## Why per-guardian Ed25519

  PW's federation signs via XMR CLSAG multisig, which does not
  support arbitrary-message signing, so state attestation cannot
  reuse the payout signing key. Ed25519-per-guardian yields N
  corroborating attestations from N pinned pubkeys — a federation-
  wide halt of one guardian still yields N-1 checkpoints the other
  guardians independently attest to.

  ## Naming

  `PerpWalk.Storage.Checkpointer` already exists and writes local
  WAL markers for pruning. This module is
  `PerpWalk.Federation.Checkpointer` — different domain, different
  purpose. Docs need the distinction explicit.

  ## Dedup gate

  A checkpoint is skipped if the WAL cursor has not advanced since
  the last checkpoint (state truly unchanged) AND the cadence
  minimum interval has not elapsed. Our own checkpoint entries
  advance the cursor, so the second condition prevents back-to-back
  checkpoints producing near-duplicates.

  ## Failure handling

  Ed25519 sign failure (missing local key) skips the checkpoint
  with a warning — dev tolerance, no writer to attest.
  Nostr publish failures are logged and swallowed — the WAL entry
  is the durable record; a separate republisher can drain to Nostr
  on a slower cadence if a relay outage leaves the entry
  unpublished (not yet implemented).
  """

  use GenServer

  alias PerpWalk.Crypto.Schnorr
  alias PerpWalk.Federation.Checkpointer.Digest
  alias PerpWalk.Federation.Keys
  alias PerpWalk.Nostr.Facade, as: NostrFacade
  alias PerpWalk.Reserves.Facade, as: ReservesFacade
  alias PerpWalk.Reserves.Snapshot
  alias PerpWalk.Role
  alias PerpWalk.Storage.Facade, as: StorageFacade
  alias PerpWalk.Storage.WAL.Sealer

  require Logger

  @default_cadence_ms :timer.minutes(15)
  @default_min_interval_ms :timer.minutes(5)
  @kind 30_081

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Test seam: runs one tick synchronously."
  @spec tick_now(GenServer.server()) :: :ok
  def tick_now(server \\ __MODULE__), do: GenServer.call(server, :tick_now, 5_000)

  # --- GenServer ---

  @impl true
  def init(opts) do
    cadence = get_config(opts, :cadence_ms, @default_cadence_ms)
    min_interval = get_config(opts, :min_interval_ms, @default_min_interval_ms)
    auto_tick = Keyword.get(opts, :auto_tick, true)

    if auto_tick, do: schedule_tick(cadence)

    {:ok,
     %{
       cadence_ms: cadence,
       min_interval_ms: min_interval,
       auto_tick: auto_tick,
       last_cursor: 0,
       last_ts_ms: 0
     }}
  end

  @impl true
  def handle_call(:tick_now, _from, state) do
    new_state = do_tick(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state = do_tick(state)
    if new_state.auto_tick, do: schedule_tick(new_state.cadence_ms)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Tick ---

  defp do_tick(state) do
    now_ms = System.system_time(:millisecond)
    cursor = Sealer.current_seq()

    cond do
      cursor == state.last_cursor ->
        # State unchanged since last checkpoint; skip.
        state

      now_ms - state.last_ts_ms < state.min_interval_ms ->
        # Within min-interval window; skip to avoid back-to-back
        # near-duplicate checkpoints.
        state

      true ->
        case emit_checkpoint(cursor) do
          :ok -> %{state | last_cursor: cursor, last_ts_ms: now_ms}
          :skip -> state
        end
    end
  end

  defp emit_checkpoint(cursor) do
    case capture_snapshot_piconeros() do
      {:ok, snapshot} ->
        state_root = Digest.compute(snapshot, cursor)

        case Keys.sign(state_root) do
          {:ok, signature} ->
            {:ok, pubkey} = Keys.local_public_key()
            payload = build_wal_payload(snapshot, cursor, signature, pubkey, state_root)
            seal_wal(payload)
            publish_nostr(payload)
            :ok

          {:error, :not_found} ->
            Logger.warning("Checkpointer: no local Ed25519 key, skipping checkpoint")
            :skip
        end

      {:error, reason} ->
        # Pre-fix the Checkpointer fell back to a zeroed snapshot and
        # SIGNED it — consumers of the attested state received "the
        # guardian confirms reserves = 0" when the actual failure was
        # Vault-unavailable. That lie has no upside: an alerting
        # subscriber can't distinguish a real 0-reserve state from a
        # temporary Vault outage. Skip the checkpoint instead; the
        # next tick retries when Vault comes back and the operator
        # sees the warning stream fill with capture failures rather
        # than a stream of signed-zero attestations.
        Logger.warning("Checkpointer: snapshot capture failed, skipping checkpoint, reason=#{inspect(reason)}")
        :skip
    end
  end

  defp capture_snapshot_piconeros do
    snapshot = ReservesFacade.capture_snapshot() |> Snapshot.to_piconeros()
    {:ok, snapshot}
  rescue
    e -> {:error, {:capture_raised, e}}
  catch
    :exit, reason -> {:error, {:capture_exited, reason}}
    :throw, value -> {:error, {:capture_threw, value}}
  end

  defp build_wal_payload(snapshot, cursor, signature, pubkey, state_root) do
    %{
      participant: Atom.to_string(Role.participant_id()),
      wal_cursor: cursor,
      held_piconeros: Map.get(snapshot, :held_piconeros, 0),
      outstanding_piconeros: Map.get(snapshot, :outstanding_piconeros, 0),
      delta_piconeros: Map.get(snapshot, :delta_piconeros, 0),
      captured_at:
        (Map.get(snapshot, :captured_at) || DateTime.utc_now())
        |> DateTime.to_iso8601(),
      state_root: Base.encode16(state_root, case: :lower),
      signature: Base.encode16(signature, case: :lower),
      pubkey: Base.encode16(pubkey, case: :lower)
    }
  end

  defp seal_wal(payload) do
    case StorageFacade.seal_and_append(:checkpoint_completed, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Checkpointer: wal append failed, reason=#{inspect(reason)}")
        :ok
    end
  end

  defp publish_nostr(payload) do
    {:ok, signing_key} = NostrFacade.venue_signing_keypair()

    case build_signed_event(payload, signing_key) do
      {:ok, event} -> publish_to_all(event)
      {:error, reason} -> Logger.warning("Checkpointer: nostr sign failed, reason=#{inspect(reason)}")
    end

    :ok
  end

  defp build_signed_event(payload, signing_key) do
    timestamp = payload.captured_at |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_unix()
    content = Jason.encode!(payload)

    tags = [
      # `d` includes participant + cursor so each guardian's
      # per-cursor checkpoint replaces cleanly at relay level
      # without stomping other guardians' checkpoints at the same
      # cursor.
      ["d", "checkpoint-#{payload.participant}-#{payload.wal_cursor}"],
      ["t", "checkpoint"],
      ["participant", payload.participant],
      ["cursor", to_string(payload.wal_cursor)]
    ]

    event = %{kind: @kind, content: content, tags: tags, created_at: timestamp}
    pubkey = signing_key.public_hex
    id = event_id(event, pubkey)

    case sign_event(id, signing_key) do
      {:ok, signature} ->
        {:ok,
         %{
           id: id,
           pubkey: pubkey,
           created_at: event.created_at,
           kind: event.kind,
           tags: event.tags,
           content: event.content,
           sig: signature
         }}

      {:error, reason} ->
        {:error, {:signing_failed, reason}}
    end
  end

  defp event_id(event, pubkey) do
    Jason.encode!([0, pubkey, event.created_at, event.kind, event.tags, event.content])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sign_event(event_id_hex, signing_key) do
    event_id_bytes = Base.decode16!(event_id_hex, case: :lower)

    case Schnorr.sign(signing_key.private, event_id_bytes) do
      {:ok, {signature, _xonly}} -> {:ok, Base.encode16(signature, case: :lower)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_to_all(event) do
    Enum.each(relays(), fn relay ->
      case NostrFacade.publish_event(relay, event) do
        {:error, reason} ->
          Logger.warning("Checkpointer: nostr publish failed, relay=#{relay}, reason=#{inspect(reason)}")

        _ok ->
          :ok
      end
    end)
  end

  defp relays do
    Application.get_env(:perpwalk, :nostr_relays, [])
  end

  defp get_config(opts, key, default) do
    Keyword.get_lazy(opts, key, fn ->
      :perpwalk
      |> Application.get_env(:federation_checkpointer, [])
      |> Keyword.get(key, default)
    end)
  end

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
