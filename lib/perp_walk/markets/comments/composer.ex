defmodule PerpWalk.Markets.Comments.Composer do
  @moduledoc """
  Builds, signs, and dispatches user comment events for PERP WALK
  markets.

  A comment is an NIP-01 kind:1 note with two tags:
    * `["t", "perpwalk-market-comment"]` — topic for relay-side
      filtering and Nostr-feed discovery
    * `["a", "30819:<venue_pubkey>:<market_id>"]` — NIP-33
      addressable reference to the market

  The author signs with their per-venue derived Nostr seckey (from
  `PerpWalk.Identity.Account.derive_nostr_keypair/1` at login,
  held in-memory in `PerpWalk.Identity.Sessions` and never
  persisted). The composer module never sees the keyphrase — only
  the derived seckey passed in by the LiveView at submit time.

  ## Build vs publish

  - `build/4` — pure: returns the wire-format event map without
    side effects. Useful for tests and for any future "save draft"
    path.
  - `publish/4` — wraps `build/4` and then (1) direct-injects into
    `PerpWalk.Markets.Comments.Inbox` so the author sees their
    comment immediately without waiting on a relay round-trip, and
    (2) fans the event out to every configured Nostr relay through
    `PerpWalk.Nostr.Relay.Client` (Tor-tunneled). Inbox dedup
    ensures the eventual relay echo doesn't produce a second copy.

  ## Constraints

  Content is required, non-empty after trim, and capped at 5_000
  bytes to keep a misuse from costing the venue Tor bandwidth and
  to keep the rendered feed scannable.
  """

  require Logger

  alias PerpWalk.Crypto.Schnorr
  alias PerpWalk.Markets.Comments.Inbox
  alias PerpWalk.Nostr.Facade, as: NostrFacade

  @market_kind 30_819
  @comment_kind 1
  @topic_tag "perpwalk-market-comment"
  @max_content_bytes 5_000

  @type signed_event :: %{
          id: String.t(),
          pubkey: String.t(),
          created_at: integer(),
          kind: integer(),
          tags: [[String.t()]],
          content: String.t(),
          sig: String.t()
        }

  @doc """
  Builds and signs a kind:1 comment event referencing the given
  market under the venue's Nostr identity.

  - `seckey` — the author's 32-byte derived Nostr secret key
    (looked up from `Identity.Sessions.lookup_nostr_seckey/1` by
    the LiveView)
  - `venue_pubkey_hex` — the venue's x-only Schnorr pubkey hex,
    used to construct the NIP-33 `a` tag
  - `market_id` — the d-tag of the market
  - `content` — user-supplied comment body

  Returns `{:ok, signed_event}` or `{:error, reason}` on input
  validation or signing failure.
  """
  @spec build(binary(), String.t(), binary(), String.t()) ::
          {:ok, signed_event()} | {:error, atom()}
  def build(seckey, venue_pubkey_hex, market_id, content)
      when is_binary(seckey) and byte_size(seckey) == 32 and
             is_binary(venue_pubkey_hex) and byte_size(venue_pubkey_hex) == 64 and
             is_binary(market_id) and is_binary(content) do
    with {:ok, trimmed} <- validate_content(content),
         {:ok, author_pubkey_hex} <- derive_author_pubkey_hex(seckey) do
      tags = base_tags(venue_pubkey_hex, market_id)

      created_at = DateTime.to_unix(DateTime.utc_now())
      event = %{kind: @comment_kind, content: trimmed, tags: tags, created_at: created_at}
      id = event_id(event, author_pubkey_hex)

      case sign_event(id, seckey) do
        {:ok, signature_hex} ->
          {:ok,
           %{
             id: id,
             pubkey: author_pubkey_hex,
             created_at: created_at,
             kind: @comment_kind,
             tags: tags,
             content: trimmed,
             sig: signature_hex
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  def build(_, _, _, _), do: {:error, :invalid_input}

  @doc """
  Builds, locally ingests, and dispatches a comment event to all
  configured relays. The local ingest happens BEFORE relay fan-out
  so the author sees their comment immediately even if Tor / relay
  delivery is slow. The Inbox's event-id dedup quietly absorbs the
  eventual relay echo.

  Returns `{:ok, %{event_id, market_id, content, ingested: :new | :duplicate}}`
  or `{:error, reason}`. Errors from `Inbox.ingest/1` are
  propagated; per-relay publish failures are logged and do NOT
  abort the call.
  """
  @spec publish(binary(), String.t(), binary(), String.t()) ::
          {:ok, %{event_id: String.t(), market_id: binary(), ingested: :new | :duplicate}}
          | {:error, atom()}
  def publish(seckey, venue_pubkey_hex, market_id, content) do
    with {:ok, event} <- build(seckey, venue_pubkey_hex, market_id, content) do
      attrs = comment_attrs(event, market_id)
      {:ok, ingested} = Inbox.ingest(attrs)

      relays = Application.get_env(:perpwalk, :nostr_relays, [])
      spawn(fn -> fan_out_to_relays(event, relays) end)

      {:ok, %{event_id: event.id, market_id: market_id, ingested: ingested}}
    end
  end

  # --- Internal ---

  defp validate_content(raw) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        {:error, :empty_content}

      byte_size(trimmed) > @max_content_bytes ->
        {:error, :content_too_long}

      true ->
        {:ok, trimmed}
    end
  end

  defp derive_author_pubkey_hex(seckey) do
    case Schnorr.pubkey_from_privkey(seckey) do
      {:ok, <<_parity, xonly::binary-32>>} ->
        {:ok, Base.encode16(xonly, case: :lower)}

      {:error, _} = err ->
        err
    end
  end

  defp event_id(event, pubkey_hex) do
    [0, pubkey_hex, event.created_at, event.kind, event.tags, event.content]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sign_event(event_id_hex, seckey) do
    msg_bytes = Base.decode16!(event_id_hex, case: :lower)

    case Schnorr.sign(seckey, msg_bytes) do
      {:ok, {signature, _xonly}} -> {:ok, Base.encode16(signature, case: :lower)}
      {:error, _} = err -> err
    end
  end

  defp comment_attrs(event, market_id) do
    %{
      event_id: event.id,
      market_id: market_id,
      author_pubkey: event.pubkey,
      content: event.content,
      created_at: event.created_at
    }
  end

  defp base_tags(venue_pubkey_hex, market_id) do
    [
      ["t", @topic_tag],
      ["a", "#{@market_kind}:#{venue_pubkey_hex}:#{market_id}"]
    ]
  end

  # Per-relay failures are logged inside the spawned task and do
  # not propagate back to the LiveView — the author's local copy
  # is already in the Inbox, so a flaky relay is not the user's
  # problem.
  @dialyzer {:nowarn_function, fan_out_to_relays: 2}

  defp fan_out_to_relays(_event, []), do: :ok

  defp fan_out_to_relays(event, relays) do
    Enum.each(relays, fn relay_url ->
      case NostrFacade.publish_event(relay_url, event) do
        {:error, reason} ->
          Logger.warning(
            "Composer: publish to relay failed, relay=#{relay_url}, " <>
              "event_id=#{event.id}, reason=#{inspect(reason)}"
          )

        _ok ->
          Logger.info("Composer: comment published, event_id=#{event.id}, relay=#{relay_url}")
      end
    end)
  end
end
