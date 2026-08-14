defmodule PerpWalk.Reserves.Publishers.Nostr do
  @moduledoc """
  Publishes reserve proofs as NIP-33 replaceable Nostr events (kind 30078).

  Signs events with a secp256k1 key stored in an encrypted key file
  via `PerpWalk.Storage.Facade.encrypt/decrypt`. Publishes to
  configured Nostr relays via WebSocket through the Tor HTTP CONNECT
  tunnel.

  Configured relays come from `Application.get_env(:perpwalk, :nostr_relays)`.
  """

  use GenServer

  require Logger

  alias PerpWalk.Crypto.Schnorr
  alias PerpWalk.Nostr.Facade, as: NostrFacade
  alias PerpWalk.Reserves.Snapshot

  @kind 30_078

  # Domain separator for the d-tag hash — prevents the derived value
  # from colliding with any other hash-of-pubkey construction this
  # codebase might grow. Baked into compile-time state only; never
  # on the wire.
  @d_tag_domain "perpwalk-reserves-d-tag-v1:"

  @doc """
  Returns the NIP-33 replaceable-event `d` tag for a single reserve
  proof cycle published by the node with the given hex pubkey at the
  given unix timestamp.

  The tag is an opaque 16-character hex hash derived from
  `pubkey || captured_at_unix` with a compile-time domain separator.
  Distinct timestamps yield distinct d-tags, so each cycle becomes
  its own addressable event on Nostr — clients can scan kind:30078
  events for the pubkey and reconstruct history without relying on
  the operator's own `/api/reserves/history`. Without the per-cycle
  bind, NIP-33's replaceable semantic would have each cycle
  superseding the prior one and Nostr would only ever carry the
  latest proof.

  No part of the value on the wire reveals the product name, so a
  leaked relay access log cannot be retroactively grepped for
  anything recognisable.
  """
  @spec d_tag(binary(), integer()) :: String.t()
  def d_tag(pubkey_hex, captured_at_unix) when is_binary(pubkey_hex) and is_integer(captured_at_unix) do
    input = @d_tag_domain <> pubkey_hex <> ":" <> Integer.to_string(captured_at_unix)

    :sha256
    |> :crypto.hash(input)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec publish_vault_proof(Vault.Proof.t()) :: {:ok, String.t()} | {:error, term()}
  def publish_vault_proof(%Vault.Proof{} = proof) do
    GenServer.call(__MODULE__, {:publish_vault, proof})
  end

  @spec pubkey() :: {:ok, String.t()} | {:error, :not_available}
  def pubkey do
    GenServer.call(__MODULE__, :pubkey)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    relays = Application.get_env(:perpwalk, :nostr_relays, [])
    {:ok, signing_key} = NostrFacade.venue_signing_keypair()

    if relays != [] do
      Logger.info("Nostr: relays configured, count=#{length(relays)}")
    end

    {:ok,
     %{
       relays: relays,
       last_event_id: nil,
       signing_key: signing_key,
       events: []
     }}
  end

  @impl true
  def handle_call(:pubkey, _from, %{signing_key: %{public_hex: hex}} = state) do
    {:reply, {:ok, hex}, state}
  end

  @impl true
  def handle_call({:publish_vault, proof}, _from, state) do
    case build_signed_event(proof, state.signing_key) do
      {:ok, signed_event} ->
        Logger.info(
          "Nostr: event prepared: id=#{signed_event.id}, kind=#{@kind}, " <>
            "pubkey=#{String.slice(signed_event.pubkey, 0, 16)}..."
        )

        # Relay publishes go out over Tor and can be slow or stall on a
        # degraded circuit. Spawn an unlinked task so the caller (Vault.Generator)
        # gets an immediate reply with the built event id, and the actual
        # relay delivery happens in the background. Per-relay errors are
        # logged inside publish_to_relays/2.
        spawn(fn -> publish_to_relays(signed_event, state.relays) end)

        updated_events = Enum.take([signed_event | state.events], 100)

        {:reply, {:ok, signed_event.id}, %{state | last_event_id: signed_event.id, events: updated_events}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Event Building ---

  defp build_signed_event(%Vault.Proof{snapshot: snap} = proof, signing_key) do
    timestamp = DateTime.to_unix(snap.captured_at)
    epoch_id = Map.get(snap.metadata, :epoch_id, 0)
    piconeros = Snapshot.to_piconeros(snap)

    # Publish the individual guardian attestations alongside the
    # summary so a consumer can independently verify each signature
    # against pinned guardian pubkeys. Pre-fix the payload only
    # carried `attestation_count`; the "multi-party proof" claim was
    # trust-us — nothing on-wire distinguished N genuine guardian
    # signatures from a single guardian claiming N=3. Base16 encoding
    # (lowercase) matches the pubkey encoding used everywhere else in
    # the venue.
    content =
      Jason.encode!(%{
        epoch_id: epoch_id,
        reserve_ratio: format_ratio(piconeros.ratio),
        held_piconeros: piconeros.held_piconeros,
        outstanding_piconeros: piconeros.outstanding_piconeros,
        attestation_count: map_size(proof.attestations),
        attestations: encode_attestations(proof.attestations),
        asset_ids: piconeros.asset_ids,
        captured_at: DateTime.to_iso8601(snap.captured_at)
      })

    tags = [
      ["d", d_tag(signing_key.public_hex, timestamp)],
      ["t", "proof-of-reserves"],
      ["epoch", to_string(epoch_id)],
      ["ratio", format_ratio(piconeros.ratio)]
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
      {:ok, {signature, _xonly}} ->
        {:ok, Base.encode16(signature, case: :lower)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Relay Publishing ---

  # Dialyzer can't see through Mint.WebSocket's opaque return types in
  # Relay.Client.publish/2 and narrows the return to its error variants.
  # Suppress the call-site pattern_match warnings — success paths are
  # exercised against real Nostr relays at runtime.
  @dialyzer {:nowarn_function, publish_to_relays: 2}

  defp publish_to_relays(_event, []), do: :ok

  defp publish_to_relays(event, relays) do
    Enum.each(relays, fn relay_url ->
      case NostrFacade.publish_event(relay_url, event) do
        {:error, reason} ->
          Logger.warning("Nostr: publish to relay failed, relay=#{relay_url}, reason=#{inspect(reason)}")

        _ok ->
          Logger.info("Nostr: published event, id=#{event.id}, relay=#{relay_url}")
      end
    end)
  end

  defp format_ratio(:infinity), do: "infinity"

  defp format_ratio(ratio) when is_number(ratio),
    do: Float.to_string(Float.round(ratio * 1.0, 6))

  # Serialises each guardian attestation as a JSON-safe map so
  # consumers can look up the guardian's pinned pubkey and
  # verify the Ed25519 signature independently. The `signature`
  # field covers a deterministic serialisation of the attestation
  # fields (see `Vault.Attestation.canonical_bytes/1`); a consumer
  # rebuilds the same canonical bytes from these fields and calls
  # `:crypto.verify(:eddsa, ...)`.
  defp encode_attestations(attestations) when is_map(attestations) do
    attestations
    |> Map.values()
    |> Enum.sort_by(& &1.guardian_id)
    |> Enum.map(fn att ->
      %{
        guardian_id: att.guardian_id,
        snapshot_id: att.snapshot_id,
        total_held: att.total_held,
        outstanding: att.outstanding,
        signature: Base.encode16(att.signature, case: :lower),
        created_at: DateTime.to_iso8601(att.created_at)
      }
    end)
  end

  # Redact signing key from crash dumps and :sys.get_state/1.
  @impl true
  def format_status(_reason, [pdict, state]) do
    redacted = %{state | signing_key: :redacted}
    [{:data, [{"State", redacted}]} | pdict]
  end
end
