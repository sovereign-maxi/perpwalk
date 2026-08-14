defmodule PerpWalk.Markets.Comments.ComposerIntegrationTest do
  @moduledoc """
  Integration tests for `PerpWalk.Markets.Comments.Composer`.

  Exercises:
    - `build/4` — pure event construction + Schnorr signing
    - `publish/4` — local Inbox ingest path + relay fan-out
      (relays default to [] in tests so fan-out is a no-op)
    - Round-trip with `PerpWalk.Nostr.Event.verify/1` +
      `comment_attributes/2`, proving that what the composer
      emits is exactly what the subscriber path accepts.
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Crypto.Schnorr
  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.Comments.{Composer, Inbox}
  alias PerpWalk.Nostr.Event, as: NostrEvent

  setup do
    Inbox.clear()

    # Build a fresh user keypair to use as the comment author.
    {:ok, {seckey, compressed_pubkey}} = Schnorr.generate_keypair()
    <<_parity, xonly::binary-32>> = compressed_pubkey

    # A stand-in venue pubkey — the Composer doesn't dereference it,
    # it just embeds it in the `a` tag.
    venue_pubkey_hex = String.duplicate("a", 64)

    {:ok, seckey: seckey, author_pubkey_hex: Base.encode16(xonly, case: :lower), venue_pubkey_hex: venue_pubkey_hex}
  end

  describe "build/4" do
    test "produces a signed kind:1 event with the right tags", ctx do
      assert {:ok, event} =
               Composer.build(ctx.seckey, ctx.venue_pubkey_hex, "market-A", "good market")

      assert event.kind == 1
      assert event.content == "good market"
      assert event.pubkey == ctx.author_pubkey_hex
      assert byte_size(event.id) == 64
      assert byte_size(event.sig) == 128

      assert ["t", "perpwalk-market-comment"] in event.tags
      assert ["a", "30819:#{ctx.venue_pubkey_hex}:market-A"] in event.tags
    end

    test "trims whitespace and rejects empty content", ctx do
      assert {:error, :empty_content} =
               Composer.build(ctx.seckey, ctx.venue_pubkey_hex, "m", "   ")

      assert {:ok, event} = Composer.build(ctx.seckey, ctx.venue_pubkey_hex, "m", "  hello  ")

      assert event.content == "hello"
    end

    test "rejects content over the 5_000 byte cap", ctx do
      long = String.duplicate("x", 5_001)

      assert {:error, :content_too_long} =
               Composer.build(ctx.seckey, ctx.venue_pubkey_hex, "m", long)
    end

    test "rejects malformed inputs", ctx do
      # Bad seckey size.
      assert {:error, :invalid_input} =
               Composer.build("too-short", ctx.venue_pubkey_hex, "m", "x")

      # Bad venue pubkey size.
      assert {:error, :invalid_input} = Composer.build(ctx.seckey, "short", "m", "x")
    end

    test "the emitted event passes Nostr.Event.verify + comment_attributes", ctx do
      {:ok, event} = Composer.build(ctx.seckey, ctx.venue_pubkey_hex, "market-X", "thesis: YES")

      # Convert atom-keyed event map to the string-keyed shape a
      # relay would deliver. This is exactly the boundary the
      # subscriber crosses.
      relay_shape = %{
        "id" => event.id,
        "pubkey" => event.pubkey,
        "created_at" => event.created_at,
        "kind" => event.kind,
        "tags" => event.tags,
        "content" => event.content,
        "sig" => event.sig
      }

      assert {:ok, verified} = NostrEvent.verify(relay_shape)
      assert {:ok, attrs} = NostrEvent.comment_attributes(verified, ctx.venue_pubkey_hex)

      assert attrs.market_id == "market-X"
      assert attrs.author_pubkey == ctx.author_pubkey_hex
      assert attrs.content == "thesis: YES"
    end
  end

  describe "publish/4" do
    test "direct-ingests the comment into the Inbox", ctx do
      assert {:ok, %{event_id: id, market_id: "m1", ingested: :new}} =
               Composer.publish(ctx.seckey, ctx.venue_pubkey_hex, "m1", "first")

      assert {:ok, comment} = Inbox.get(id)
      assert comment.content == "first"
      assert comment.market_id == "m1"
      assert comment.author_pubkey == ctx.author_pubkey_hex
    end

    test "publishes CommentReceived for the LiveView consumer", ctx do
      :ok = EventBus.subscribe(MarketsEvents.CommentReceived)

      {:ok, _} = Composer.publish(ctx.seckey, ctx.venue_pubkey_hex, "m2", "for live feed")

      assert_receive %MarketsEvents.CommentReceived{
                       content: "for live feed",
                       market_id: "m2",
                       author_pubkey: pk
                     },
                     500

      assert pk == ctx.author_pubkey_hex
    end

    test "the local ingest reports :duplicate on a re-publish of identical content", ctx do
      # Same seckey, same content, same market — but `build/4`
      # stamps `created_at` from the current second. If we call
      # twice in the same second, the id is identical, so the
      # second call should report :duplicate. If a tick passes
      # between them, both are :new. Either is acceptable
      # behaviour as long as the Inbox stays correct, so this
      # test asserts the Inbox count tracks the distinct-event
      # count, not the publish count.
      {:ok, _} = Composer.publish(ctx.seckey, ctx.venue_pubkey_hex, "m3", "tick-test")
      count_after_first = Inbox.count()

      {:ok, %{ingested: state}} =
        Composer.publish(ctx.seckey, ctx.venue_pubkey_hex, "m3", "tick-test")

      case state do
        :duplicate -> assert Inbox.count() == count_after_first
        :new -> assert Inbox.count() == count_after_first + 1
      end
    end

    test "validation errors propagate", ctx do
      assert {:error, :empty_content} =
               Composer.publish(ctx.seckey, ctx.venue_pubkey_hex, "m", "")
    end
  end
end
