defmodule PerpWalk.Federation.Health.Bridge do
  @moduledoc """
  Translates `Cartel.Events.Bus` peer/quorum events into PERP WALK's
  `Federation` event surface.

  Cartel's `Health.Monitor` already detects peer-down / peer-recovered
  and quorum-lost / quorum-restored via the heartbeat mesh and
  publishes them on its own pubsub bus. PERP WALK's product code
  shouldn't import cartel types directly — instead this bridge
  subscribes to cartel's bus and re-publishes equivalent events on
  the PERP WALK EventBus.

  Without this bridge, the PIP-event-subscription surface in
  `PerpWalkWeb.Live.Helpers` has no way to react to peer transitions
  in real time; the LiveView health pip only updates when the
  periodic poll catches up.

  Subscribes to: `:peer`, `:quorum` topics on `Cartel.Events.Bus.Registry`.
  Republishes to PERP WALK EventBus as
  `PerpWalk.Events.Federation.{PeerLost, PeerJoined, QuorumLost,
  QuorumRestored}`.
  """

  use GenServer

  require Logger

  alias Cartel.Events.Bus, as: CartelBus

  alias Cartel.Events, as: CartelEvents

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents

  @default_registry Cartel.Events.Bus.Registry

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, @default_registry)

    CartelBus.subscribe(registry, :peer)
    CartelBus.subscribe(registry, :quorum)

    {:ok, %{registry: registry}}
  end

  @impl true
  def handle_info({CartelBus, :peer, %CartelEvents.PeerDown{peer_id: id, timestamp: ts}}, state) do
    EventBus.publish(%FederationEvents.PeerLost{peer_id: id, timestamp: ts})
    Logger.warning("Bridge: peer lost, peer_id=#{inspect(id)}")
    {:noreply, state}
  end

  def handle_info(
        {CartelBus, :peer, %CartelEvents.PeerRecovered{peer_id: id, timestamp: ts}},
        state
      ) do
    EventBus.publish(%FederationEvents.PeerJoined{peer_id: id, timestamp: ts})
    Logger.info("Bridge: peer joined, peer_id=#{inspect(id)}")
    {:noreply, state}
  end

  def handle_info(
        {CartelBus, :quorum, %CartelEvents.QuorumLost{online: online, threshold: threshold, timestamp: ts}},
        state
      ) do
    EventBus.publish(%FederationEvents.QuorumLost{
      online: online,
      threshold: threshold,
      timestamp: ts
    })

    Logger.warning("Bridge: quorum lost, online=#{online}, threshold=#{threshold}")
    {:noreply, state}
  end

  def handle_info(
        {CartelBus, :quorum, %CartelEvents.QuorumRestored{online: online, threshold: threshold, timestamp: ts}},
        state
      ) do
    EventBus.publish(%FederationEvents.QuorumRestored{
      online: online,
      threshold: threshold,
      timestamp: ts
    })

    Logger.info("Bridge: quorum restored, online=#{online}, threshold=#{threshold}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
