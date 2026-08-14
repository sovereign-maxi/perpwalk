defmodule PerpWalk.Events do
  @moduledoc """
  Cross-domain communication substrate.

  Owns the typed `EventBus` (a thin wrapper over `Phoenix.PubSub`),
  the per-domain event taxonomy under `PerpWalk.Events.<Domain>`, and
  the `Display` protocol used to render events into human-readable
  output for logs, dashboards, and Nostr DMs.

  ## Topic derivation

  A topic is derived from the event struct's module path, dropping
  the `PerpWalk.Events` prefix and snake-casing each remaining
  segment:

      PerpWalk.Events.Markets.MarketCreated     → "events:markets:market_created"
      PerpWalk.Events.Storage.WalRotated        → "events:storage:wal_rotated"

  Subscribers subscribe by event-struct module — typos become
  compile errors, and `handle_info/2` receives the bare struct (no
  envelope to unwrap).
  """

  defmodule EventBus do
    @moduledoc """
    Typed publish/subscribe bus for `PerpWalk.Events.*` event structs.

    Wraps `Phoenix.PubSub` (named `PerpWalk.PubSub`, started by the
    application supervisor). Topics are auto-derived from the event
    module's name — see `PerpWalk.Events` for the convention.
    """

    @pubsub PerpWalk.PubSub

    @doc "Broadcasts `event` to every subscriber of its derived topic."
    @spec publish(struct()) :: :ok
    def publish(%{__struct__: _} = event) do
      Phoenix.PubSub.local_broadcast(@pubsub, topic_for_event(event), event)
    end

    @doc """
    Broadcasts `event` to a per-instance sub-topic (e.g. a market id),
    in addition to the base topic. Subscribers can scope to a single
    aggregate's stream.
    """
    @spec publish(struct(), String.t()) :: :ok
    def publish(%{__struct__: _} = event, topic_suffix) do
      base = topic_for_event(event)
      Phoenix.PubSub.local_broadcast(@pubsub, "#{base}:#{topic_suffix}", event)
    end

    @doc "Subscribes the current process to every event of `event_module`."
    @spec subscribe(module()) :: :ok | {:error, term()}
    def subscribe(event_module) when is_atom(event_module) do
      Phoenix.PubSub.subscribe(@pubsub, topic_for_module(event_module))
    end

    @doc "Subscribes the current process to a per-instance sub-topic."
    @spec subscribe(module(), String.t()) :: :ok | {:error, term()}
    def subscribe(event_module, topic_suffix) when is_atom(event_module) do
      base = topic_for_module(event_module)
      Phoenix.PubSub.subscribe(@pubsub, "#{base}:#{topic_suffix}")
    end

    @doc "Unsubscribes the current process from `event_module`."
    @spec unsubscribe(module()) :: :ok
    def unsubscribe(event_module) when is_atom(event_module) do
      Phoenix.PubSub.unsubscribe(@pubsub, topic_for_module(event_module))
    end

    @doc "Unsubscribes the current process from a per-instance sub-topic."
    @spec unsubscribe(module(), String.t()) :: :ok
    def unsubscribe(event_module, topic_suffix) when is_atom(event_module) do
      base = topic_for_module(event_module)
      Phoenix.PubSub.unsubscribe(@pubsub, "#{base}:#{topic_suffix}")
    end

    @doc "Topic string for `event_module`. Public so tests and tooling can introspect."
    @spec topic_for_module(module()) :: String.t()
    def topic_for_module(module) when is_atom(module) do
      module
      |> Module.split()
      |> Enum.drop(2)
      |> Enum.map_join(":", &Macro.underscore/1)
      |> then(&"events:#{&1}")
    end

    defp topic_for_event(%{__struct__: module}), do: topic_for_module(module)
  end
end
