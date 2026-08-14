defmodule PerpWalk.Federation.Alerter do
  @moduledoc """
  Halt-transition attestation publisher.

  Ticks every `:cadence_ms` (default 5s), watches
  `Telemetry.Health.System.halted?/0`, and on every operational ↔
  halted transition:

  1. Seals a `:halt_alert` WAL entry carrying the new state,
     reason, this guardian's participant id, and a `kind` tag
     (`:manual` / `:auto` / `:cleared`).
  2. Publishes a NIP-01 kind-30079 event signed by the local
     guardian's venue Nostr identity via `Nostr.Facade`.

  Signed by the local Nostr identity — NOT the multisig key. A
  federation-wide halt (quorum lost, elementsd unreachable) may be
  the exact condition preventing multisig rounds from completing.
  Each guardian speaks for itself; a federation-wide halt produces
  multiple independent corroborating attestations from different
  pubkeys.

  ## Idempotency

  Only transitions produce alerts. A tick that observes the same
  state as the previous tick emits nothing. The WAL is scanned on
  init to recover the last observed state so a restart doesn't
  re-emit the current condition as a "fresh" transition.

  ## Failure handling

  Nostr publish failures are logged and swallowed — a WAL-appended
  `:halt_alert` is the durable record. A separate republisher can
  drain the WAL to Nostr on a slower cadence if a relay outage
  leaves the alert unpublished (not yet implemented).
  """

  use GenServer

  alias Locker.WAL.Entry
  alias PerpWalk.Crypto.Schnorr
  alias PerpWalk.Nostr.Facade, as: NostrFacade
  alias PerpWalk.Role
  alias PerpWalk.Storage.Facade, as: StorageFacade
  alias PerpWalk.Telemetry.Health.System, as: HealthSystem

  require Logger

  @default_cadence_ms :timer.seconds(5)
  @kind 30_079

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
    cadence =
      Keyword.get_lazy(opts, :cadence_ms, fn ->
        :perpwalk
        |> Application.get_env(:federation_alerter, [])
        |> Keyword.get(:cadence_ms, @default_cadence_ms)
      end)

    auto_tick = Keyword.get(opts, :auto_tick, true)

    last = recover_last_state()

    if auto_tick, do: schedule_tick(cadence)

    {:ok, %{cadence_ms: cadence, auto_tick: auto_tick, last_state: last}}
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
    current = current_state()

    if current == state.last_state do
      state
    else
      emit_alert(current)
      %{state | last_state: current}
    end
  end

  defp current_state do
    if HealthSystem.halted?(),
      do: {:halted, HealthSystem.halt_reason() || "unknown"},
      else: :operational
  end

  defp emit_alert(state) do
    participant = Role.participant_id()
    now = DateTime.utc_now()

    {kind, reason} =
      case state do
        {:halted, r} -> {:halted, r}
        :operational -> {:cleared, nil}
      end

    payload = %{
      state: state_label(kind),
      reason: reason,
      participant: Atom.to_string(participant),
      at: DateTime.to_iso8601(now)
    }

    seal_wal(payload)
    publish_nostr(payload)
    :ok
  end

  defp state_label(:halted), do: "halted"
  defp state_label(:cleared), do: "operational"

  defp seal_wal(payload) do
    case StorageFacade.seal_and_append(:halt_alert, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Alerter: wal append failed, reason=#{inspect(reason)}")
        :ok
    end
  end

  defp publish_nostr(payload) do
    {:ok, signing_key} = NostrFacade.venue_signing_keypair()

    case build_signed_event(payload, signing_key) do
      {:ok, event} -> publish_to_all(event)
      {:error, reason} -> Logger.warning("Alerter: nostr sign failed, reason=#{inspect(reason)}")
    end

    :ok
  end

  defp build_signed_event(payload, signing_key) do
    timestamp = payload.at |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_unix()
    content = Jason.encode!(payload)

    tags = [
      ["d", "halt-#{payload.participant}"],
      ["t", "halt-alert"],
      ["state", payload.state],
      ["participant", payload.participant]
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
          Logger.warning("Alerter: nostr publish failed, relay=#{relay}, reason=#{inspect(reason)}")

        _ok ->
          :ok
      end
    end)
  end

  defp relays do
    Application.get_env(:perpwalk, :nostr_relays, [])
  end

  # --- Init helpers ---

  # Recover the last observed state from the WAL so a restart
  # doesn't re-alert the current condition as a fresh transition.
  # Missing (never alerted before) defaults to :operational so the
  # first-ever halt still fires.
  defp recover_last_state do
    case StorageFacade.read_all_wal() do
      {:ok, entries} -> last_alert_state(entries)
      _ -> :operational
    end
  end

  defp last_alert_state(entries) do
    entries
    |> Enum.reduce(nil, fn
      %Entry{type: :halt_alert, payload: %{state: label, reason: reason}}, _acc ->
        payload_state(label, reason)

      _, acc ->
        acc
    end)
    |> Kernel.||(:operational)
  end

  defp payload_state("halted", reason) when is_binary(reason), do: {:halted, reason}
  defp payload_state("halted", _), do: {:halted, "unknown"}
  defp payload_state(_, _), do: :operational

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
