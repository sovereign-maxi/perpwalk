defmodule PerpWalk.Markets.Comments.InboxIntegrationTest do
  @moduledoc "Integration tests for PerpWalk.Markets.Comments.Inbox."

  use PerpWalk.IntegrationCase

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.Comments.Inbox

  setup do
    Inbox.clear()
    :ok
  end

  defp comment(opts \\ []) do
    %{
      event_id: Keyword.get(opts, :event_id, random_hex(64)),
      market_id: Keyword.get(opts, :market_id, "market-#{System.unique_integer([:positive])}"),
      author_pubkey: Keyword.get(opts, :author_pubkey, random_hex(64)),
      content: Keyword.get(opts, :content, "test content"),
      created_at: Keyword.get(opts, :created_at, System.system_time(:second))
    }
  end

  defp random_hex(len) do
    :crypto.strong_rand_bytes(div(len, 2)) |> Base.encode16(case: :lower)
  end

  describe "ingest/1" do
    test "stores a fresh comment and returns :new" do
      attrs = comment()

      assert {:ok, :new} = Inbox.ingest(attrs)
      assert {:ok, stored} = Inbox.get(attrs.event_id)
      assert stored.event_id == attrs.event_id
      assert stored.market_id == attrs.market_id
      assert stored.content == attrs.content
      assert is_integer(stored.received_at_ms)
    end

    test "dedups on event_id and returns :duplicate the second time" do
      attrs = comment()

      assert {:ok, :new} = Inbox.ingest(attrs)
      assert {:ok, :duplicate} = Inbox.ingest(attrs)
      assert {:ok, :duplicate} = Inbox.ingest(attrs)

      assert Inbox.count() == 1
    end

    test "publishes a CommentReceived event on a new ingest" do
      :ok = EventBus.subscribe(MarketsEvents.CommentReceived)
      attrs = comment(content: "fresh take on YES")

      {:ok, :new} = Inbox.ingest(attrs)

      assert_receive %MarketsEvents.CommentReceived{
                       event_id: id,
                       content: "fresh take on YES",
                       market_id: mid
                     },
                     500

      assert id == attrs.event_id
      assert mid == attrs.market_id
    end

    test "does NOT publish CommentReceived on a duplicate ingest" do
      :ok = EventBus.subscribe(MarketsEvents.CommentReceived)
      attrs = comment()

      {:ok, :new} = Inbox.ingest(attrs)
      assert_receive %MarketsEvents.CommentReceived{}, 500

      {:ok, :duplicate} = Inbox.ingest(attrs)
      refute_receive %MarketsEvents.CommentReceived{}, 100
    end

    test "refuses comments referencing an unknown market_id when the existence check is on" do
      # Production mode: the inbox config flag is enabled. A Nostr
      # publisher who signs a comment tagged at a market_id that
      # doesn't exist in Markets.Store gets dropped on the floor —
      # the primary table doesn't fill with attacker-chosen IDs.
      prior = Application.get_env(:perpwalk, :inbox, [])
      Application.put_env(:perpwalk, :inbox, Keyword.put(prior, :require_market_existence, true))

      try do
        attrs = comment(market_id: "does-not-exist-#{System.unique_integer([:positive])}")

        assert {:ok, :unknown_market} = Inbox.ingest(attrs)
        assert {:error, :not_found} = Inbox.get(attrs.event_id)
        assert Inbox.count() == 0
      after
        Application.put_env(:perpwalk, :inbox, prior)
      end
    end

    test "politely drops content over the per-comment size ceiling" do
      attrs = comment(content: String.duplicate("x", 5_001))

      assert {:ok, :oversized} = Inbox.ingest(attrs)
      assert {:error, :not_found} = Inbox.get(attrs.event_id)
      assert Inbox.count() == 0
    end

    test "accepts content exactly at the size ceiling" do
      attrs = comment(content: String.duplicate("x", 5_000))
      assert {:ok, :new} = Inbox.ingest(attrs)
    end
  end

  describe "replicate_entries/1" do
    test "drops oversized replicated payloads instead of inserting them" do
      entry = %Locker.WAL.Entry{
        type: :comment_ingested,
        payload: %{
          event_id: random_hex(64),
          market_id: "m-repl",
          author_pubkey: random_hex(64),
          content: String.duplicate("y", 5_001),
          created_at: System.system_time(:second),
          received_at_ms: System.system_time(:millisecond)
        }
      }

      assert :ok = Inbox.replicate_entries([entry])
      assert Inbox.count() == 0
    end

    test "applies well-formed replicated payloads" do
      attrs = comment()

      entry = %Locker.WAL.Entry{
        type: :comment_ingested,
        payload: %{
          event_id: attrs.event_id,
          market_id: attrs.market_id,
          author_pubkey: attrs.author_pubkey,
          content: attrs.content,
          created_at: attrs.created_at,
          received_at_ms: System.system_time(:millisecond)
        }
      }

      assert :ok = Inbox.replicate_entries([entry])
      assert {:ok, _} = Inbox.get(attrs.event_id)
    end
  end

  describe "list_for_market/1" do
    test "returns comments sorted by created_at descending (newest first)" do
      market_id = "list-market"

      Inbox.ingest(comment(market_id: market_id, created_at: 100, content: "oldest"))
      Inbox.ingest(comment(market_id: market_id, created_at: 300, content: "newest"))
      Inbox.ingest(comment(market_id: market_id, created_at: 200, content: "middle"))

      [first, second, third] = Inbox.list_for_market(market_id)

      assert first.content == "newest"
      assert second.content == "middle"
      assert third.content == "oldest"
    end

    test "scopes results to the requested market_id" do
      Inbox.ingest(comment(market_id: "m1", content: "for m1"))
      Inbox.ingest(comment(market_id: "m2", content: "for m2"))

      [c1] = Inbox.list_for_market("m1")
      [c2] = Inbox.list_for_market("m2")

      assert c1.content == "for m1"
      assert c2.content == "for m2"
      assert Inbox.list_for_market("never-existed") == []
    end

    test "returns empty list for a market with no comments" do
      assert Inbox.list_for_market("empty-market") == []
    end
  end

  describe "get/1" do
    test "returns the comment by event_id" do
      attrs = comment()
      {:ok, :new} = Inbox.ingest(attrs)

      assert {:ok, fetched} = Inbox.get(attrs.event_id)
      assert fetched.event_id == attrs.event_id
    end

    test "returns :not_found for unknown ids" do
      assert {:error, :not_found} = Inbox.get(random_hex(64))
    end
  end

  describe "count/0" do
    test "tracks the distinct number of comments cached" do
      assert Inbox.count() == 0

      Inbox.ingest(comment())
      Inbox.ingest(comment())
      assert Inbox.count() == 2

      # Duplicate doesn't bump the count.
      same = comment()
      Inbox.ingest(same)
      Inbox.ingest(same)
      assert Inbox.count() == 3
    end
  end
end
