defmodule PerpWalk.Sim.Invariants.Creator.Economics do
  @moduledoc """
  Verifies the creator-LP economic contract holds end-to-end:

  1. **Seed math** — at market creation, the AMM pool is seeded
     from the creator's `deposit_amount` at `unit_size`. Both sides
     start with `to_subunits(deposit_amount / unit_size)`. Any drift
     here means `Maker.create_market/1` seeded the pool
     inconsistently with the deposit — a fund-loss-shaped bug.

  2. **Residual math** — when a `:creator_lp_return` payout is
     enqueued, its amount must equal the deterministic value
     `Cashier.lp_return_amount/1` derives from live market state
     (winning-side reserve × unit_size for `:settled`, full
     deposit for `:voided`). Any drift here would mean the
     creator gets paid the wrong amount, or the operator eats
     the delta silently.

  Both checks are event-driven and O(1) per event:

  - `MarketCreated` → look up the fresh market, verify seed math.
  - `PayoutRequested{kind: :creator_lp_return}` → look up the
     market, verify residual math.

  ## Rules-engine parity

  `Federation.Rules.creator_lp_expected_amount/1` runs the same
  residual math at sign time. This invariant duplicates it
  deliberately — a bug in the shared derivation would be caught
  by either check independently, and the invariant fires during
  the sim's `check/1` cadence rather than waiting for the Signer's
  tick.
  """

  use GenServer

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.AMM
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Markets.Services.Cashier

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec check(map()) :: :ok | {:violation, map()}
  def check(_snapshot) do
    case GenServer.call(__MODULE__, :snapshot) do
      [] ->
        :ok

      violations ->
        {:violation,
         %{
           kind: :creator_lp_drift,
           count: length(violations),
           sample: Enum.take(violations, 5)
         }}
    end
  end

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # --- GenServer ---

  @impl true
  def init(_opts) do
    EventBus.subscribe(MarketsEvents.MarketCreated)
    EventBus.subscribe(FederationEvents.PayoutRequested)

    {:ok, %{violations_by_key: %{}}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.values(state.violations_by_key), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | violations_by_key: %{}}}
  end

  @impl true
  def handle_info(%MarketsEvents.MarketCreated{market_id: mid}, state) do
    {:noreply, check_seed(state, mid)}
  end

  def handle_info(
        %FederationEvents.PayoutRequested{
          request_id: rid,
          market_id: mid,
          kind: :creator_lp_return,
          amount_piconeros: amount
        },
        state
      ) do
    {:noreply, check_residual(state, rid, mid, amount)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  # Both sides seeded equally at `to_subunits(deposit_amount / unit_size)`.
  # A mismatch here means the AMM pool doesn't reflect the deposit the
  # creator actually paid — either the derived pool depth is wrong or
  # the pool was seeded from something other than the deposit.
  defp check_seed(state, market_id) do
    case MarketsFacade.get_market(market_id) do
      {:ok, market} ->
        depth_contracts = div(market.deposit_amount, market.unit_size)
        expected = AMM.to_subunits(depth_contracts)

        if market.pool.yes == expected and market.pool.no == expected do
          state
        else
          record(state, {:seed_drift, market_id}, %{
            kind: :seed_drift,
            market_id: market_id,
            deposit_amount: market.deposit_amount,
            unit_size: market.unit_size,
            expected_reserve_subunits: expected,
            actual_yes: market.pool.yes,
            actual_no: market.pool.no
          })
        end

      _ ->
        state
    end
  end

  defp check_residual(state, request_id, market_id, amount) do
    case MarketsFacade.get_market(market_id) do
      {:ok, market} ->
        expected = Cashier.lp_return_amount(market)

        if amount == expected do
          state
        else
          record(state, {:residual_drift, request_id}, %{
            kind: :residual_drift,
            request_id: request_id,
            market_id: market_id,
            market_status: market.status,
            outcome: market.outcome,
            deposit_amount: market.deposit_amount,
            expected_amount: expected,
            actual_amount: amount
          })
        end

      _ ->
        state
    end
  end

  defp record(state, key, violation) do
    %{state | violations_by_key: Map.put(state.violations_by_key, key, violation)}
  end
end
