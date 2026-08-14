defmodule PerpWalk.EventsIntegrationTest do
  @moduledoc """
  Integration tests for `PerpWalk.Events.EventBus` against the
  application-supervised `PerpWalk.PubSub`.
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets

  @now ~U[2026-04-29 12:00:00Z]

  describe "topic_for_module/1" do
    test "drops PerpWalk.Events prefix and snake-cases the rest" do
      assert EventBus.topic_for_module(Markets.MarketCreated) ==
               "events:markets:market_created"

      assert EventBus.topic_for_module(Markets.PositionOpened) ==
               "events:markets:position_opened"

      assert EventBus.topic_for_module(Markets.ResolutionReversed) ==
               "events:markets:resolution_reversed"
    end
  end

  describe "publish/1 + subscribe/1" do
    test "subscriber receives a published event as a bare struct" do
      :ok = EventBus.subscribe(Markets.MarketCreated)

      event = %Markets.MarketCreated{
        market_id: "mkt-1",
        description: "Will it rain?",
        category: :politics,
        creator_account_id: "acct-a",
        timestamp: @now
      }

      :ok = EventBus.publish(event)

      assert_receive ^event, 1_000

      EventBus.unsubscribe(Markets.MarketCreated)
    end

    test "non-subscribers do not receive the event" do
      :ok = EventBus.subscribe(Markets.MarketActivated)

      event = %Markets.MarketCreated{
        market_id: "mkt-2",
        description: "x",
        category: :crypto,
        creator_account_id: "acct-b",
        timestamp: @now
      }

      :ok = EventBus.publish(event)

      refute_receive %Markets.MarketCreated{}, 100

      EventBus.unsubscribe(Markets.MarketActivated)
    end

    test "two subscribers each receive the event" do
      parent = self()

      child =
        spawn_link(fn ->
          :ok = EventBus.subscribe(Markets.MarketSettled)
          send(parent, :ready)

          receive do
            %Markets.MarketSettled{} = e -> send(parent, {:child, e})
          after
            1_000 -> send(parent, :child_timeout)
          end
        end)

      assert_receive :ready, 1_000

      :ok = EventBus.subscribe(Markets.MarketSettled)

      event = %Markets.MarketSettled{
        market_id: "mkt-3",
        outcome: :yes,
        resolved_at: @now,
        timestamp: @now
      }

      :ok = EventBus.publish(event)

      assert_receive ^event, 1_000
      assert_receive {:child, ^event}, 1_000

      EventBus.unsubscribe(Markets.MarketSettled)
      Process.exit(child, :kill)
    end
  end

  describe "publish/2 + subscribe/2 (per-instance topic)" do
    test "subscribers to a sub-topic only see events on that sub-topic" do
      :ok = EventBus.subscribe(Markets.PositionOpened, "mkt-A")

      event_a = %Markets.PositionOpened{
        position_id: "pos-a",
        market_id: "mkt-A",
        account_id: "acct-a",
        side: :yes,
        contracts: 10,
        amount_paid: 1_000,
        timestamp: @now
      }

      event_b = %Markets.PositionOpened{
        position_id: "pos-b",
        market_id: "mkt-B",
        account_id: "acct-b",
        side: :no,
        contracts: 20,
        amount_paid: 2_000,
        timestamp: @now
      }

      :ok = EventBus.publish(event_a, "mkt-A")
      :ok = EventBus.publish(event_b, "mkt-B")

      assert_receive ^event_a, 1_000
      refute_receive ^event_b, 100

      EventBus.unsubscribe(Markets.PositionOpened, "mkt-A")
    end
  end

  describe "unsubscribe/1" do
    test "stops further deliveries" do
      :ok = EventBus.subscribe(Markets.MarketActivated)
      :ok = EventBus.unsubscribe(Markets.MarketActivated)

      event = %Markets.MarketActivated{market_id: "mkt-X", timestamp: @now}
      :ok = EventBus.publish(event)

      refute_receive %Markets.MarketActivated{}, 100
    end
  end
end
