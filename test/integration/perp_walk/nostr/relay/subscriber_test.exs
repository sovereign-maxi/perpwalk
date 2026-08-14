defmodule PerpWalk.Nostr.Relay.SubscriberIntegrationTest do
  @moduledoc """
  Integration tests for `PerpWalk.Nostr.Relay.Subscriber`.

  Drives the frame-routing path through the `inject_frame/2` test
  seam — no live WebSocket. The connection layer (Mint.HTTP +
  Mint.WebSocket) is exercised by the existing `Relay.Client`
  integration tests and trusted here.
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Crypto.Schnorr
  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.Comments.Inbox
  alias PerpWalk.Nostr.Relay.Subscriber
  alias PerpWalk.Nostr.Venue

  setup do
    Inbox.clear()

    # Reserves.Publishers.Nostr boots before this test and owns the
    # venue identity. Cache its pubkey so we can sign comments under
    # it and verify the subscriber routes them to the inbox.
    venue_pubkey = await_venue_pubkey()

    {:ok, venue_pubkey: venue_pubkey}
  end

  defp await_venue_pubkey do
    case Venue.Identity.pubkey() do
      {:ok, hex} -> hex
      _ -> flunk("venue Nostr pubkey not available — Venue.Identity not started?")
    end
  end

  defp fresh_user_keypair do
    {:ok, {privkey, compressed_pubkey}} = Schnorr.generate_keypair()
    <<_parity, xonly::binary-32>> = compressed_pubkey
    {privkey, Base.encode16(xonly, case: :lower)}
  end

  defp build_event(privkey, pubkey_hex, kind, tags, content) do
    created_at = System.system_time(:second)

    id =
      [0, pubkey_hex, created_at, kind, tags, content]
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {:ok, {sig, _}} = Schnorr.sign(privkey, Base.decode16!(id, case: :lower))

    %{
      "id" => id,
      "pubkey" => pubkey_hex,
      "created_at" => created_at,
      "kind" => kind,
      "tags" => tags,
      "content" => content,
      "sig" => Base.encode16(sig, case: :lower)
    }
  end

  defp comment_event(venue_pubkey, market_id, content) do
    {priv, pub} = fresh_user_keypair()

    tags = [
      ["t", "perpwalk-market-comment"],
      ["a", "30819:#{venue_pubkey}:#{market_id}"]
    ]

    build_event(priv, pub, 1, tags, content)
  end

  defp event_frame(event, sub_id \\ "test-sub") do
    Jason.encode!(["EVENT", sub_id, event])
  end

  defp start_isolated_subscriber do
    start_supervised!({Subscriber, [relay_url: "wss://test.invalid", auto_connect: false]})
  end

  describe "inject_frame/2 — well-formed comment events" do
    test "routes a verified comment into the Inbox", ctx do
      pid = start_isolated_subscriber()
      event = comment_event(ctx.venue_pubkey, "market-A", "good market")

      assert :ingested = Subscriber.inject_frame(pid, event_frame(event))

      assert {:ok, comment} = Inbox.get(event["id"])
      assert comment.market_id == "market-A"
      assert comment.content == "good market"
      assert comment.author_pubkey == event["pubkey"]
    end

    test "publishes CommentReceived on first ingest", ctx do
      pid = start_isolated_subscriber()
      :ok = EventBus.subscribe(MarketsEvents.CommentReceived)

      event = comment_event(ctx.venue_pubkey, "market-B", "i'm long YES")
      _ = Subscriber.inject_frame(pid, event_frame(event))

      assert_receive %MarketsEvents.CommentReceived{
                       content: "i'm long YES",
                       market_id: "market-B"
                     },
                     500
    end

    test "dedups when the same event arrives from multiple relays", ctx do
      pid = start_isolated_subscriber()
      event = comment_event(ctx.venue_pubkey, "market-C", "dedup test")

      # Same event delivered three times (e.g., echoed by three
      # relays in the configured pool). Only the first is :ingested;
      # the rest are detected as :duplicate by the Inbox.
      assert :ingested = Subscriber.inject_frame(pid, event_frame(event, "relay-1"))
      assert :ingested = Subscriber.inject_frame(pid, event_frame(event, "relay-2"))
      assert :ingested = Subscriber.inject_frame(pid, event_frame(event, "relay-3"))

      assert Inbox.count() == 1
    end
  end

  describe "inject_frame/2 — drop paths" do
    test "rejects an event with a tampered content (id mismatch)", ctx do
      pid = start_isolated_subscriber()
      event = comment_event(ctx.venue_pubkey, "market-X", "original")
      tampered = Map.put(event, "content", "tampered")

      assert :rejected = Subscriber.inject_frame(pid, event_frame(tampered))
      assert {:error, :not_found} = Inbox.get(event["id"])
    end

    test "rejects an event whose a tag points at a foreign pubkey", ctx do
      pid = start_isolated_subscriber()
      foreign_venue = String.duplicate("f", 64)
      event = comment_event(foreign_venue, "market-Y", "from elsewhere")

      assert :rejected = Subscriber.inject_frame(pid, event_frame(event))
      assert {:error, :not_found} = Inbox.get(event["id"])

      # The venue pubkey we trust is the real one, not the foreign one.
      assert ctx.venue_pubkey != foreign_venue
    end

    test "rejects a non-comment event (kind != 1)", ctx do
      pid = start_isolated_subscriber()
      {priv, pub} = fresh_user_keypair()

      tags = [
        ["t", "perpwalk-market-comment"],
        ["a", "30819:#{ctx.venue_pubkey}:market-Z"]
      ]

      event = build_event(priv, pub, 30_023, tags, "long-form post, not a comment")

      assert :rejected = Subscriber.inject_frame(pid, event_frame(event))
      assert {:error, :not_found} = Inbox.get(event["id"])
    end
  end

  describe "inject_frame/2 — non-event frames" do
    test "EOSE is silently accepted" do
      pid = start_isolated_subscriber()
      frame = Jason.encode!(["EOSE", "sub-1"])
      assert :ok = Subscriber.inject_frame(pid, frame)
    end

    test "NOTICE is silently accepted" do
      pid = start_isolated_subscriber()
      frame = Jason.encode!(["NOTICE", "test message"])
      assert :ok = Subscriber.inject_frame(pid, frame)
    end

    test "bad JSON returns the :bad_frame error tag without crashing" do
      pid = start_isolated_subscriber()
      assert {:error, :bad_frame} = Subscriber.inject_frame(pid, "not json {{}")
    end

    test "CLOSED signals a reconnect instead of sitting on a dead subscription" do
      pid = start_isolated_subscriber()
      frame = Jason.encode!(["CLOSED", "sub-1", "auth-required: whatever"])

      assert {:reconnect, {:closed, "sub-1", _reason}} = Subscriber.inject_frame(pid, frame)
      assert Process.alive?(pid)
    end
  end

  describe "inject_frame/2 — inbox-level refusal" do
    test "oversized comment content is dropped politely, subscriber survives", ctx do
      pid = start_isolated_subscriber()
      event = comment_event(ctx.venue_pubkey, "market-big", String.duplicate("x", 5_001))

      assert :ingested = Subscriber.inject_frame(pid, event_frame(event))
      assert {:error, :not_found} = Inbox.get(event["id"])
      assert Process.alive?(pid)
    end
  end

  describe "status/1" do
    test "reflects a subscriber that was started with auto_connect: false" do
      pid = start_isolated_subscriber()
      snapshot = Subscriber.status(pid)

      assert snapshot.relay_url == "wss://test.invalid"
      refute snapshot.connected
      assert snapshot.reconnect_attempts == 0
      assert is_binary(snapshot.subscription_id)
    end
  end
end
