defmodule PerpWalk.Markets.Publishers.Nostr do
  @moduledoc """
  Publishes market lifecycle state as NIP-33 replaceable Nostr events
  (kind 30819).

  Subscribes to the `PerpWalk.Events.Markets.*` lifecycle events that
  change publicly-visible state — `MarketDepositConfirmed`,
  `MarketActivated`, `MarketRejected`, `MarketExpired`,
  `ResolutionSubmitted`, `ResolutionReversed`, `MarketSettled`,
  `MarketVoided` — fetches the latest `Market.t()` from
  `PerpWalk.Markets.Store`, builds a signed Nostr event, and dispatches
  it to every configured relay via `PerpWalk.Nostr.Relay.Client`
  (which routes through the Tor HTTP CONNECT tunnel).

  NIP-33 semantics make this self-superseding: the tuple
  `(pubkey, kind=30819, d=market_id)` identifies the event, so each
  republish replaces the previous state for that market across the
  relay set. Clients always see the latest snapshot without us
  needing to "delete" prior versions.

  ## Signing key

  The venue's Nostr identity is the same key
  `Reserves.Publishers.Nostr` uses for proof-of-reserves — both
  publishers load the same encrypted key file
  (`Storage.Facade.key_file("nostr-signing-key")`). The key is
  loaded lazily on first publish so this module doesn't race against
  Reserves at boot (the application supervisor brings Reserves up
  after Markets). If a publish fires before the key file exists,
  we log a warning and skip — there is no fallback identity.

  ## Failure handling

  Relay publishes go out asynchronously in a spawned task, mirroring
  the Reserves publisher. The owning GenServer reply is immediate;
  per-relay failures are logged inside the spawned task and do not
  propagate back. This keeps a slow relay (Tor circuit issues, busy
  relay) from blocking market events.
  """

  use GenServer

  require Logger

  alias PerpWalk.Crypto.Schnorr
  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.{AMM, Market, Store}
  alias PerpWalk.Nostr.Facade, as: NostrFacade

  # Custom kind in the NIP-33 parameterized-replaceable range
  # (30000–39999). 30819 has no widely-deployed prior art so clients
  # that don't know about PERP WALK will just ignore it; the topic
  # tag `t=perpwalk-market` is the affirmative filter.
  @kind 30_819

  @event_subscriptions [
    MarketsEvents.MarketDepositConfirmed,
    MarketsEvents.MarketActivated,
    MarketsEvents.MarketRejected,
    MarketsEvents.MarketExpired,
    MarketsEvents.ResolutionSubmitted,
    MarketsEvents.ResolutionReversed,
    MarketsEvents.MarketSettled,
    MarketsEvents.MarketVoided
  ]

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Publishes the current state of a specific market to all configured
  relays. Exposed for tests and operator iex sessions; the normal
  push path is the EventBus subscription set up in `init/1`.

  Returns `{:ok, event_id_hex}` if the event was built and dispatched
  (relay deliveries happen in a spawned task — successful return
  here does NOT guarantee acceptance by any specific relay).
  `{:error, reason}` if the market cannot be fetched, the signing
  key is unavailable, or the event cannot be signed.
  """
  @spec publish_market(binary()) :: {:ok, String.t()} | {:error, term()}
  def publish_market(market_id) when is_binary(market_id) do
    GenServer.call(__MODULE__, {:publish, market_id})
  end

  @doc """
  Returns the most recently built Nostr event (the same map shape
  used on the wire — `%{id, pubkey, kind, tags, content, sig,
  created_at}`), or `nil` if no event has been built yet.

  Operator debugging seam — answers "what did we last publish?"
  without scraping logs. Also used by tests to verify event shape
  without subscribing to a real relay.
  """
  @spec last_event() :: map() | nil
  def last_event do
    GenServer.call(__MODULE__, :last_event)
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    Enum.each(@event_subscriptions, &EventBus.subscribe/1)

    relays = Application.get_env(:perpwalk, :nostr_relays, [])
    signing_key = load_signing_key_or_nil()

    if relays != [] and signing_key != nil do
      Logger.info("Nostr: relays configured, count=#{length(relays)}")
    end

    {:ok, %{relays: relays, signing_key: signing_key, last_event: nil}}
  end

  # `Nostr.Venue.Identity` may not be up at Markets.Supervisor start
  # (dev boot without a venue identity, test teardown timing). Pre-
  # fix the pattern match `{:ok, key} = ...` raised MatchError inside
  # init/1, crash-looping the Markets supervisor. Fall back to a nil
  # signing_key so the publisher boots subscribed but every publish
  # short-circuits at the missing-key check.
  defp load_signing_key_or_nil do
    {:ok, key} = NostrFacade.venue_signing_keypair()
    key
  rescue
    e ->
      Logger.warning("Nostr: venue signing key raised (#{inspect(e)}); publisher running in no-op mode")

      nil
  catch
    :exit, reason ->
      Logger.warning("Nostr: venue signing key unavailable (#{inspect(reason)}); publisher running in no-op mode")

      nil
  end

  @impl true
  def handle_call({:publish, market_id}, _from, state) do
    case do_publish(market_id, state) do
      {{:ok, event_id}, new_state} -> {:reply, {:ok, event_id}, new_state}
      {{:error, reason}, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:last_event, _from, state) do
    {:reply, state.last_event, state}
  end

  @impl true
  def handle_info(%MarketsEvents.MarketDepositConfirmed{market_id: id}, state),
    do: handle_lifecycle(id, state)

  def handle_info(%MarketsEvents.MarketActivated{market_id: id}, state),
    do: handle_lifecycle(id, state)

  def handle_info(%MarketsEvents.MarketRejected{market_id: id}, state),
    do: handle_lifecycle(id, state)

  def handle_info(%MarketsEvents.MarketExpired{market_id: id}, state),
    do: handle_lifecycle(id, state)

  def handle_info(%MarketsEvents.ResolutionSubmitted{market_id: id}, state),
    do: handle_lifecycle(id, state)

  def handle_info(%MarketsEvents.ResolutionReversed{market_id: id}, state),
    do: handle_lifecycle(id, state)

  def handle_info(%MarketsEvents.MarketSettled{market_id: id}, state),
    do: handle_lifecycle(id, state)

  def handle_info(%MarketsEvents.MarketVoided{market_id: id}, state),
    do: handle_lifecycle(id, state)

  def handle_info(_msg, state), do: {:noreply, state}

  # Redact the in-memory signing key from crash dumps and
  # `:sys.get_state/1`. Matches the Reserves.Publishers.Nostr pattern.
  @impl true
  def format_status(_reason, [pdict, state]) do
    redacted = %{state | signing_key: :redacted}
    [{:data, [{"State", redacted}]} | pdict]
  end

  defp handle_lifecycle(market_id, state) do
    {_result, new_state} = do_publish(market_id, state)
    {:noreply, new_state}
  end

  # --- Internal ---

  defp do_publish(_market_id, %{signing_key: nil} = state) do
    # No-op mode: publisher booted without a venue signing key.
    # Skip silently — every published market would fail the same
    # way, so log-per-market would just spam the warning stream.
    {{:error, :no_signing_key}, state}
  end

  defp do_publish(market_id, state) do
    with {:ok, market} <- fetch_market(market_id),
         {:ok, signed_event} <- build_signed_event(market, state.signing_key) do
      Logger.info(
        "Nostr: event prepared, market_id=#{market_id}, " <>
          "event_id=#{signed_event.id}, status=#{market.status}"
      )

      relays = state.relays
      spawn(fn -> publish_to_relays(signed_event, relays) end)

      {{:ok, signed_event.id}, %{state | last_event: signed_event}}
    else
      {:error, :market_not_found} = err ->
        Logger.warning("Nostr: market not found, market_id=#{market_id}")
        {err, state}

      {:error, reason} = err ->
        Logger.warning("Nostr: publish failed, market_id=#{market_id}, reason=#{inspect(reason)}")
        {err, state}
    end
  end

  defp fetch_market(market_id) do
    case Store.get_market(market_id) do
      {:ok, market} -> {:ok, market}
      {:error, :not_found} -> {:error, :market_not_found}
    end
  end

  # --- Event Building ---

  defp build_signed_event(%Market{} = market, signing_key) do
    timestamp = DateTime.to_unix(DateTime.utc_now())
    tags = build_tags(market)
    content = build_content(market)

    event = %{kind: @kind, content: content, tags: tags, created_at: timestamp}
    pubkey = signing_key.public_hex
    id = event_id(event, pubkey)

    case sign_event(id, signing_key) do
      {:ok, signature} ->
        {:ok,
         %{
           id: id,
           pubkey: pubkey,
           created_at: event.created_at,
           kind: event.kind,
           tags: event.tags,
           content: event.content,
           sig: signature
         }}

      {:error, reason} ->
        {:error, {:signing_failed, reason}}
    end
  end

  defp build_tags(%Market{} = market) do
    base = [
      ["d", market.id],
      ["t", "perpwalk-market"],
      ["status", Atom.to_string(market.status)],
      ["category", Atom.to_string(market.category)],
      ["expiry", DateTime.to_iso8601(market.expiry)],
      ["resolution_deadline", DateTime.to_iso8601(market.resolution_deadline)]
    ]

    case market.outcome do
      nil -> base
      outcome -> base ++ [["outcome", Atom.to_string(outcome)]]
    end
  end

  defp build_content(%Market{} = market) do
    # Pool reserves are stored in AMM subunits internally; publish
    # in contract units so external consumers see human-meaningful
    # liquidity numbers. Ratios (probability) are scale-invariant.
    scale = AMM.pool_scale()

    Jason.encode!(%{
      description: market.description,
      resolution_criterion: market.resolution_criterion,
      category: market.category,
      status: market.status,
      outcome: market.outcome,
      pool: %{yes: div(market.pool.yes, scale), no: div(market.pool.no, scale)},
      unit_size: market.unit_size,
      expiry: DateTime.to_iso8601(market.expiry),
      resolution_deadline: DateTime.to_iso8601(market.resolution_deadline),
      created_at: DateTime.to_iso8601(market.created_at)
    })
  end

  defp event_id(event, pubkey) do
    [0, pubkey, event.created_at, event.kind, event.tags, event.content]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sign_event(event_id_hex, signing_key) do
    event_id_bytes = Base.decode16!(event_id_hex, case: :lower)

    case Schnorr.sign(signing_key.private, event_id_bytes) do
      {:ok, {signature, _xonly}} -> {:ok, Base.encode16(signature, case: :lower)}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Relay Publishing ---

  # Dialyzer can't see through Mint.WebSocket's opaque return types in
  # Relay.Client.publish/2 and narrows the return to its error variants.
  # Suppress the call-site pattern_match warnings — success paths are
  # exercised against real Nostr relays at runtime.
  @dialyzer {:nowarn_function, publish_to_relays: 2}

  defp publish_to_relays(_event, []), do: :ok

  defp publish_to_relays(event, relays) do
    Enum.each(relays, fn relay_url ->
      case NostrFacade.publish_event(relay_url, event) do
        {:error, reason} ->
          Logger.warning("Nostr: publish to relay failed, relay=#{relay_url}, reason=#{inspect(reason)}")

        _ok ->
          Logger.info("Nostr: published event, id=#{event.id}, relay=#{relay_url}")
      end
    end)
  end
end
