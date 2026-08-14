defmodule PerpWalk.Nostr.Event do
  @moduledoc """
  Pure NIP-01 event parsing and verification.

  Takes a raw Nostr event map (as decoded from a relay's
  `["EVENT", subscription_id, event]` frame) and either returns a
  verified internal representation or `{:error, reason}`. Verification
  re-derives the event id from the canonical NIP-01 serialization and
  checks the BIP-340 Schnorr signature against the author's x-only
  pubkey.

  Also exposes `comment_attributes/1` to extract the PERP WALK-specific
  fields (market_id from the `a` tag, content, author, created_at)
  from a verified kind:1 comment event.

  Pure module — no IO, no state.
  """

  alias PerpWalk.Crypto.Schnorr

  # NIP-33 addressable event reference format. Comments target a
  # specific market via this addressable reference, which is stable
  # across the market's lifecycle republishes (the publisher's
  # event id changes on each transition, but `(kind, pubkey, d_tag)`
  # stays fixed for the same market).
  @market_kind 30_819
  @comment_kind 1
  @market_topic_tag "perpwalk-market-comment"

  @type raw_event :: %{
          optional(String.t()) => term()
        }

  @type verified_event :: %{
          id: String.t(),
          pubkey: String.t(),
          created_at: integer(),
          kind: integer(),
          tags: [[String.t()]],
          content: String.t(),
          sig: String.t()
        }

  @type comment_attrs :: %{
          event_id: String.t(),
          author_pubkey: String.t(),
          market_id: binary(),
          content: String.t(),
          created_at: integer()
        }

  # --- Verification ---

  @doc """
  Verifies a raw decoded Nostr event map.

  Confirms:
    - Required fields present with the right types
    - `id` matches the SHA-256 of the canonical NIP-01 serialization
    - `sig` verifies under BIP-340 Schnorr against `pubkey` and `id`

  Returns the event as a typed map on success. Any failure short-
  circuits to `{:error, reason}` — callers (Inbox, Subscriber) drop
  the event silently rather than letting it propagate.
  """
  @spec verify(raw_event()) :: {:ok, verified_event()} | {:error, atom()}
  def verify(%{} = raw) do
    with {:ok, fields} <- extract_fields(raw),
         :ok <- check_id(fields),
         :ok <- check_signature(fields) do
      {:ok, fields}
    end
  end

  def verify(_), do: {:error, :not_a_map}

  @doc """
  Extracts the PERP WALK comment-specific fields from a verified
  event. Returns `{:error, :not_a_comment}` if the event isn't a
  kind:1 note carrying the `perpwalk-market-comment` topic tag and
  a valid `a` tag pointing at a market under the venue Nostr key.

  `venue_pubkey_hex` is the x-only pubkey hex string the venue's
  market publisher uses to sign market lifecycle events. We accept
  comments whose `a` tag references events from that exact pubkey
  and kind — this prevents comments under a forged market id from
  some other Nostr key polluting our inbox.
  """
  @spec comment_attributes(verified_event(), String.t()) ::
          {:ok, comment_attrs()} | {:error, atom()}
  def comment_attributes(%{kind: @comment_kind} = event, venue_pubkey_hex)
      when is_binary(venue_pubkey_hex) do
    with :ok <- check_topic_tag(event.tags),
         {:ok, market_id} <- extract_market_id(event.tags, venue_pubkey_hex) do
      {:ok,
       %{
         event_id: event.id,
         author_pubkey: event.pubkey,
         market_id: market_id,
         content: event.content,
         created_at: event.created_at
       }}
    end
  end

  def comment_attributes(%{kind: _other}, _), do: {:error, :not_a_comment}
  def comment_attributes(_, _), do: {:error, :not_a_comment}

  # --- Internal ---

  defp extract_fields(raw) do
    with {:ok, id} <- fetch_hex32(raw, "id"),
         {:ok, pubkey} <- fetch_hex32(raw, "pubkey"),
         {:ok, sig} <- fetch_hex64(raw, "sig"),
         {:ok, created_at} <- fetch_int(raw, "created_at"),
         {:ok, kind} <- fetch_int(raw, "kind"),
         {:ok, tags} <- fetch_tags(raw),
         {:ok, content} <- fetch_string(raw, "content") do
      {:ok,
       %{
         id: id,
         pubkey: pubkey,
         created_at: created_at,
         kind: kind,
         tags: tags,
         content: content,
         sig: sig
       }}
    end
  end

  defp fetch_hex32(raw, key) do
    case Map.get(raw, key) do
      <<v::binary-size(64)>> ->
        if v =~ ~r/^[0-9a-f]{64}$/, do: {:ok, v}, else: {:error, {:not_hex, key}}

      _ ->
        {:error, {:missing_or_bad_field, key}}
    end
  end

  defp fetch_hex64(raw, key) do
    case Map.get(raw, key) do
      <<v::binary-size(128)>> ->
        if v =~ ~r/^[0-9a-f]{128}$/, do: {:ok, v}, else: {:error, {:not_hex, key}}

      _ ->
        {:error, {:missing_or_bad_field, key}}
    end
  end

  defp fetch_int(raw, key) do
    case Map.get(raw, key) do
      v when is_integer(v) -> {:ok, v}
      _ -> {:error, {:missing_or_bad_field, key}}
    end
  end

  defp fetch_string(raw, key) do
    case Map.get(raw, key) do
      v when is_binary(v) -> {:ok, v}
      _ -> {:error, {:missing_or_bad_field, key}}
    end
  end

  defp fetch_tags(raw) do
    case Map.get(raw, "tags") do
      tags when is_list(tags) ->
        if Enum.all?(tags, &valid_tag?/1), do: {:ok, tags}, else: {:error, :bad_tags}

      _ ->
        {:error, {:missing_or_bad_field, "tags"}}
    end
  end

  defp valid_tag?([_ | _] = tag), do: Enum.all?(tag, &is_binary/1)
  defp valid_tag?(_), do: false

  defp check_id(fields) do
    expected =
      [0, fields.pubkey, fields.created_at, fields.kind, fields.tags, fields.content]
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, fields.id),
      do: :ok,
      else: {:error, :id_mismatch}
  end

  defp check_signature(fields) do
    with {:ok, pubkey_bytes} <- decode_hex(fields.pubkey, 32),
         {:ok, sig_bytes} <- decode_hex(fields.sig, 64),
         {:ok, id_bytes} <- decode_hex(fields.id, 32) do
      case Schnorr.verify(pubkey_bytes, id_bytes, sig_bytes) do
        :ok -> :ok
        {:error, _} -> {:error, :bad_signature}
      end
    end
  end

  defp decode_hex(hex, expected_bytes) do
    case Base.decode16(hex, case: :lower) do
      {:ok, bin} when byte_size(bin) == expected_bytes -> {:ok, bin}
      _ -> {:error, :hex_decode_failed}
    end
  end

  defp check_topic_tag(tags) do
    if Enum.any?(tags, fn
         ["t", @market_topic_tag] -> true
         _ -> false
       end),
       do: :ok,
       else: {:error, :missing_topic_tag}
  end

  # The `a` tag value is `<kind>:<pubkey>:<d>`. For a PERP WALK market
  # comment we require kind=30819 and pubkey=venue_pubkey_hex; the d
  # segment becomes the market_id. Multiple `a` tags are allowed in
  # NIP-01 in general, but we accept the FIRST one that matches the
  # venue's market kind and pubkey.
  defp extract_market_id(tags, venue_pubkey_hex) do
    expected_prefix = "#{@market_kind}:#{venue_pubkey_hex}:"

    Enum.find_value(tags, {:error, :no_market_reference}, fn
      ["a", value] when is_binary(value) ->
        if String.starts_with?(value, expected_prefix) do
          market_id = String.replace_prefix(value, expected_prefix, "")
          if market_id == "", do: false, else: {:ok, market_id}
        else
          false
        end

      _ ->
        false
    end)
  end
end
