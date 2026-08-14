defmodule PerpWalk.Nostr.Supervisor do
  @moduledoc """
  Domain-root supervisor for the Nostr bounded context.

  Aggregates the two long-lived Nostr children — the venue-signing
  identity (`Venue.Identity`) and the relay subscription tree
  (`Subscription.Supervisor`) — under one supervisor so the
  application root sees a single Nostr entry rather than wiring the
  pieces individually.

  `:rest_for_one` so a `Venue.Identity` crash also restarts the
  subscription tree (subscribers carry the venue pubkey for relay
  authentication; an identity restart invalidates that cached state
  and the subscribers need to rehydrate).
  """

  use Supervisor

  alias PerpWalk.Nostr.{Subscription, Venue}

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      Venue.Identity,
      Subscription.Supervisor
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 3, max_seconds: 60)
  end
end
