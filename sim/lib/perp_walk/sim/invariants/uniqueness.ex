defmodule PerpWalk.Sim.Invariants.Uniqueness do
  @moduledoc """
  Verifies no two entities share a deposit subaddress.

  Subaddresses are allocated per market, per quote, and per dispute
  via the `:subaddress_provider`. The provider's monotonic counter
  guarantees uniqueness within a sim run; this invariant verifies
  that property by examining what actually persists.

  A duplicate would mean the provider returned the same index
  twice, OR the persistence layer collapsed two distinct
  allocations into one record. Either is a critical bug.

  Cross-entity uniqueness too: a market and a dispute should not
  both reference the same subaddress.

  ## Event-driven

  Subscribes to `MarketCreated`, `QuoteCreated`, and `DisputeFlagged`.
  On each event the entity's subaddress is captured (from the event
  payload where available, otherwise via a direct ETS lookup) and
  recorded in a `(subaddress → first_owner)` map. A second insert
  for the same subaddress with a different owner records the
  duplicate. Per-event cost is O(1); per-check cost is
  O(violations_seen).

  The earlier snapshot-scanning version walked the full markets,
  disputes, and quotes ETS tables on every validate call. Even in
  baseline it was the single most expensive invariant; under
  adversarial state accumulation the cumulative cost dominated the
  run wallclock and produced the per-tick slowdown that surfaced
  in the long-horizon Phase B run.
  """

  use GenServer

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Sim.Run

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Validator contract — snapshot ignored, state held in the GenServer."
  @spec check(map()) :: :ok | {:violation, map()}
  def check(_snapshot) do
    case GenServer.call(__MODULE__, :snapshot) do
      [] ->
        :ok

      duplicates ->
        {:violation,
         %{
           kind: :duplicate_subaddress,
           count: length(duplicates),
           sample: Enum.take(duplicates, 3)
         }}
    end
  end

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # --- GenServer ---

  @impl true
  def init(_opts) do
    EventBus.subscribe(MarketsEvents.MarketCreated)
    EventBus.subscribe(MarketsEvents.QuoteCreated)
    EventBus.subscribe(MarketsEvents.DisputeFlagged)

    {:ok,
     %{
       # subaddress => {kind, entity_id} for the first owner seen
       first_owners: %{},
       # subaddress => violation_map (dedup by subaddress)
       violations: %{}
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.values(state.violations), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | first_owners: %{}, violations: %{}}}
  end

  @impl true
  def handle_info(
        %MarketsEvents.MarketCreated{market_id: market_id, timestamp: ts},
        state
      ) do
    if Run.from_current_run?(ts) do
      {:noreply, record_market(state, market_id)}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        %MarketsEvents.QuoteCreated{
          quote_id: quote_id,
          subaddress: addr,
          timestamp: ts
        },
        state
      )
      when is_binary(addr) do
    if Run.from_current_run?(ts) do
      {:noreply, record_owner(state, addr, {:quote, quote_id})}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        %MarketsEvents.DisputeFlagged{
          account_id: account_id,
          market_id: market_id,
          timestamp: ts
        },
        state
      ) do
    if Run.from_current_run?(ts) do
      {:noreply, record_dispute(state, account_id, market_id)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp record_market(state, market_id) do
    case MarketsFacade.get_market(market_id) do
      {:ok, %{deposit_subaddress: addr}} when is_binary(addr) ->
        record_owner(state, addr, {:market, market_id})

      _ ->
        state
    end
  end

  defp record_dispute(state, account_id, market_id) do
    case MarketsFacade.get_dispute(account_id, market_id) do
      {:ok, %{deposit_subaddress: addr}} when is_binary(addr) ->
        record_owner(state, addr, {:dispute, {account_id, market_id}})

      _ ->
        state
    end
  end

  defp record_owner(state, addr, new_owner) do
    case Map.fetch(state.first_owners, addr) do
      :error ->
        %{state | first_owners: Map.put(state.first_owners, addr, new_owner)}

      {:ok, ^new_owner} ->
        # Re-emit of the same event — not a violation.
        state

      {:ok, prior_owner} ->
        violation = %{addr: addr, entries: [prior_owner, new_owner]}
        %{state | violations: Map.put_new(state.violations, addr, violation)}
    end
  end
end
