defmodule PerpWalk.Nostr.EventTest do
  @moduledoc "Unit tests for PerpWalk.Nostr.Event verification and comment extraction."

  use ExUnit.Case, async: true

  alias PerpWalk.Crypto.Schnorr
  alias PerpWalk.Nostr.Event

  # Build a fully-signed Nostr event for tests. Mirrors what a real
  # client would do: assemble fields, derive the canonical id, sign.
  defp signed_event(privkey, pubkey_hex, attrs) do
    base = %{
      "kind" => Map.get(attrs, :kind, 1),
      "content" => Map.get(attrs, :content, "hello"),
      "tags" => Map.get(attrs, :tags, []),
      "created_at" => Map.get(attrs, :created_at, 1_700_000_000),
      "pubkey" => pubkey_hex
    }

    id =
      [
        0,
        base["pubkey"],
        base["created_at"],
        base["kind"],
        base["tags"],
        base["content"]
      ]
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {:ok, {sig, _xonly}} = Schnorr.sign(privkey, Base.decode16!(id, case: :lower))

    Map.merge(base, %{
      "id" => id,
      "sig" => Base.encode16(sig, case: :lower)
    })
  end

  defp fresh_keypair do
    {:ok, {privkey, compressed_pubkey}} = Schnorr.generate_keypair()
    <<_parity, xonly::binary-32>> = compressed_pubkey
    {privkey, Base.encode16(xonly, case: :lower)}
  end

  describe "verify/1" do
    test "accepts a correctly signed event with matching id" do
      {priv, pub} = fresh_keypair()
      raw = signed_event(priv, pub, %{})

      assert {:ok, verified} = Event.verify(raw)
      assert verified.id == raw["id"]
      assert verified.pubkey == pub
      assert verified.sig == raw["sig"]
    end

    test "rejects when id doesn't match the canonical serialization" do
      {priv, pub} = fresh_keypair()
      raw = signed_event(priv, pub, %{})
      tampered = Map.put(raw, "id", String.duplicate("0", 64))

      assert {:error, :id_mismatch} = Event.verify(tampered)
    end

    test "rejects when content is changed after signing (id mismatch)" do
      {priv, pub} = fresh_keypair()
      raw = signed_event(priv, pub, %{content: "original"})
      tampered = Map.put(raw, "content", "tampered")

      assert {:error, :id_mismatch} = Event.verify(tampered)
    end

    test "rejects when the signature is from a different key" do
      {priv, pub} = fresh_keypair()
      {wrong_priv, _} = fresh_keypair()
      base = signed_event(priv, pub, %{})

      bad =
        {:ok, {wrong_sig, _}} = Schnorr.sign(wrong_priv, Base.decode16!(base["id"], case: :lower))

      _ = bad
      tampered = Map.put(base, "sig", Base.encode16(wrong_sig, case: :lower))

      assert {:error, :bad_signature} = Event.verify(tampered)
    end

    test "rejects missing required fields" do
      {priv, pub} = fresh_keypair()
      raw = signed_event(priv, pub, %{})

      for field <- ["id", "pubkey", "sig", "created_at", "kind", "tags", "content"] do
        stripped = Map.delete(raw, field)
        assert {:error, _} = Event.verify(stripped), "should have rejected with #{field} missing"
      end
    end

    test "rejects non-map input" do
      assert {:error, :not_a_map} = Event.verify("not a map")
      assert {:error, :not_a_map} = Event.verify(nil)
      assert {:error, :not_a_map} = Event.verify(123)
    end

    test "rejects malformed tags (non-list, non-string-list)" do
      {priv, pub} = fresh_keypair()
      raw = signed_event(priv, pub, %{})

      assert {:error, _} = Event.verify(Map.put(raw, "tags", "not a list"))
      assert {:error, _} = Event.verify(Map.put(raw, "tags", [[1, 2, 3]]))
    end
  end

  describe "comment_attributes/2" do
    setup do
      {priv, pub} = fresh_keypair()
      venue_pubkey_hex = String.duplicate("a", 64)
      {:ok, %{priv: priv, pub: pub, venue_pubkey_hex: venue_pubkey_hex}}
    end

    test "extracts market_id, author, content for a well-formed comment", ctx do
      market_id = "market-123"

      tags = [
        ["t", "perpwalk-market-comment"],
        ["a", "30819:#{ctx.venue_pubkey_hex}:#{market_id}"]
      ]

      raw = signed_event(ctx.priv, ctx.pub, %{kind: 1, content: "i think YES", tags: tags})
      {:ok, verified} = Event.verify(raw)

      assert {:ok, attrs} = Event.comment_attributes(verified, ctx.venue_pubkey_hex)
      assert attrs.market_id == market_id
      assert attrs.author_pubkey == ctx.pub
      assert attrs.content == "i think YES"
      assert attrs.event_id == verified.id
      assert is_integer(attrs.created_at)
    end

    test "rejects events whose kind is not 1", ctx do
      tags = [
        ["t", "perpwalk-market-comment"],
        ["a", "30819:#{ctx.venue_pubkey_hex}:market-x"]
      ]

      raw = signed_event(ctx.priv, ctx.pub, %{kind: 30_023, content: "x", tags: tags})
      {:ok, verified} = Event.verify(raw)

      assert {:error, :not_a_comment} = Event.comment_attributes(verified, ctx.venue_pubkey_hex)
    end

    test "rejects events missing the perpwalk-market-comment topic tag", ctx do
      tags = [["a", "30819:#{ctx.venue_pubkey_hex}:market-x"]]
      raw = signed_event(ctx.priv, ctx.pub, %{kind: 1, content: "x", tags: tags})
      {:ok, verified} = Event.verify(raw)

      assert {:error, :missing_topic_tag} =
               Event.comment_attributes(verified, ctx.venue_pubkey_hex)
    end

    test "rejects events whose a tag points at a different kind", ctx do
      tags = [
        ["t", "perpwalk-market-comment"],
        ["a", "1:#{ctx.venue_pubkey_hex}:market-x"]
      ]

      raw = signed_event(ctx.priv, ctx.pub, %{kind: 1, content: "x", tags: tags})
      {:ok, verified} = Event.verify(raw)

      assert {:error, :no_market_reference} =
               Event.comment_attributes(verified, ctx.venue_pubkey_hex)
    end

    test "rejects events whose a tag points at a different pubkey", ctx do
      other_venue = String.duplicate("b", 64)

      tags = [
        ["t", "perpwalk-market-comment"],
        ["a", "30819:#{other_venue}:market-x"]
      ]

      raw = signed_event(ctx.priv, ctx.pub, %{kind: 1, content: "x", tags: tags})
      {:ok, verified} = Event.verify(raw)

      assert {:error, :no_market_reference} =
               Event.comment_attributes(verified, ctx.venue_pubkey_hex)
    end

    test "rejects events missing the a tag entirely", ctx do
      tags = [["t", "perpwalk-market-comment"]]
      raw = signed_event(ctx.priv, ctx.pub, %{kind: 1, content: "x", tags: tags})
      {:ok, verified} = Event.verify(raw)

      assert {:error, :no_market_reference} =
               Event.comment_attributes(verified, ctx.venue_pubkey_hex)
    end
  end
end
