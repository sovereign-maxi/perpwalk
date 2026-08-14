defmodule PerpWalk.Markets.Publishers.NostrIntegrationTest do
  @moduledoc """
  Integration tests for `PerpWalk.Markets.Publishers.Nostr`.

  Runs against the application-supervised publisher with relays
  configured to the empty list — relay traffic is exercised by the
  Tor-routed client tests; this file verifies event building,
  signing, EventBus subscription, and NIP-33 shape.

  The publisher loads its signing key lazily from the same
  encrypted file the Reserves publisher uses. Reserves boots after
  Markets in the application supervisor, so by the time the first
  market event fires, the key file exists and the lazy load succeeds.
  """

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers,
    only: [activate!: 1, pending_market!: 1]

  alias PerpWalk.Markets.Publishers
  alias PerpWalk.Markets.Services.Resolver
  alias PerpWalk.TestHelpers.ProcessHelpers

  describe "publish_market/1" do
    test "builds and signs a NIP-33 event for an existing market" do
      market = pending_market!([])

      assert {:ok, event_id} = Publishers.Nostr.publish_market(market.id)
      assert is_binary(event_id)
      assert byte_size(event_id) == 64
      assert event_id =~ ~r/^[0-9a-f]{64}$/

      event = Publishers.Nostr.last_event()
      assert event != nil
      assert event.id == event_id
      assert event.kind == 30_819
      assert is_binary(event.sig)
      assert byte_size(event.sig) == 128
    end

    test "returns :market_not_found for unknown market_id" do
      assert {:error, :market_not_found} =
               Publishers.Nostr.publish_market("nonexistent-market-id")
    end

    test "the event's d-tag is the market_id (NIP-33 replaceable key)" do
      market = pending_market!([])
      {:ok, _} = Publishers.Nostr.publish_market(market.id)

      event = Publishers.Nostr.last_event()

      d_tag =
        Enum.find(event.tags, fn
          ["k" <> _, _] -> false
          [k, _v] -> k == "d"
        end)

      assert d_tag == ["d", market.id]
    end

    test "tags include topic, status, category, and timestamps" do
      market = pending_market!([])
      {:ok, _} = Publishers.Nostr.publish_market(market.id)

      tags = Publishers.Nostr.last_event().tags
      assert ["t", "perpwalk-market"] in tags
      assert ["status", "pending"] in tags
      assert Enum.any?(tags, fn tag -> match?(["category", _], tag) end)
      assert Enum.any?(tags, fn tag -> match?(["expiry", _], tag) end)
      assert Enum.any?(tags, fn tag -> match?(["resolution_deadline", _], tag) end)
    end

    test "outcome tag is absent until resolution is submitted" do
      market = pending_market!([])
      {:ok, _} = Publishers.Nostr.publish_market(market.id)

      tags = Publishers.Nostr.last_event().tags
      refute Enum.any?(tags, fn tag -> match?(["outcome", _], tag) end)
    end

    test "content is JSON-decodable and carries market state" do
      market = pending_market!([])
      {:ok, _} = Publishers.Nostr.publish_market(market.id)

      assert {:ok, payload} = Jason.decode(Publishers.Nostr.last_event().content)

      assert payload["description"] == market.description
      assert payload["status"] == "pending"
      assert payload["category"] == Atom.to_string(market.category)
      assert is_map(payload["pool"])
      assert is_integer(payload["pool"]["yes"])
      assert is_integer(payload["pool"]["no"])
    end

    test "the event verifies under BIP-340 Schnorr against its pubkey" do
      market = pending_market!([])
      {:ok, _} = Publishers.Nostr.publish_market(market.id)

      event = Publishers.Nostr.last_event()

      # Reconstruct the canonical id bytes per NIP-01, then verify
      # the signature against the event's pubkey. This is exactly
      # what a Nostr relay does on receipt.
      derived_id =
        Jason.encode!([
          0,
          event.pubkey,
          event.created_at,
          event.kind,
          event.tags,
          event.content
        ])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert derived_id == event.id

      xonly_pubkey = Base.decode16!(event.pubkey, case: :lower)
      sig = Base.decode16!(event.sig, case: :lower)
      msg = Base.decode16!(event.id, case: :lower)

      assert :ok = PerpWalk.Crypto.Schnorr.verify(xonly_pubkey, msg, sig)
    end
  end

  describe "EventBus subscription" do
    test "publishes a fresh event on MarketActivated" do
      market = pending_market!([])
      {:ok, _} = Publishers.Nostr.publish_market(market.id)

      before_event = Publishers.Nostr.last_event()
      assert before_event != nil

      # Activate the market — fires MarketActivated, which the
      # publisher subscribes to. The handle_info path should
      # republish with the new status.
      _activated = activate!(market)
      :ok = await_publish_after(before_event.id)

      after_event = Publishers.Nostr.last_event()
      refute after_event.id == before_event.id

      tags = after_event.tags
      assert ["status", "active"] in tags
      assert {:ok, payload} = Jason.decode(after_event.content)
      assert payload["status"] == "active"
    end

    test "publishes again on ResolutionSubmitted with outcome tag set" do
      market = pending_market!([]) |> activate!()
      {:ok, _} = Publishers.Nostr.publish_market(market.id)
      before_id = Publishers.Nostr.last_event().id

      {:ok, _} = Resolver.expire(market.id)
      :ok = await_publish_after(before_id)
      after_expire_id = Publishers.Nostr.last_event().id

      {:ok, _} = Resolver.submit_resolution(market.id, :yes)
      :ok = await_publish_after(after_expire_id)

      event = Publishers.Nostr.last_event()
      assert ["outcome", "yes"] in event.tags
      assert ["status", "resolving"] in event.tags
    end
  end

  # The publisher processes EventBus messages asynchronously in its
  # own mailbox. Polls via `ProcessHelpers.await_condition/2`
  # (the only sanctioned home for the underlying sleep) until the
  # last_event id changes from `prior_id`.
  defp await_publish_after(prior_id) do
    ProcessHelpers.await_condition(fn ->
      case Publishers.Nostr.last_event() do
        %{id: id} when id != prior_id -> true
        _ -> false
      end
    end)
  end
end
