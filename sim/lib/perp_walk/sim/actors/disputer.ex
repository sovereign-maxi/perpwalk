defmodule PerpWalk.Sim.Actors.Disputer do
  @moduledoc """
  Sim actor that flags disputes on `:resolving` markets.

  Honest disputer strategy:
  - Each tick, with probability `:dispute_p` (low), scan
    `:resolving` markets the actor hasn't already disputed and
    flag one. Confirms the deposit immediately (sim shortcut).
  - With probability `:cancel_p`, occasionally cancels a freshly
    flagged dispute mid-modal — exercises the cancel-on-close
    path.

  Sybil and spam variants are separate modules.

  ## State

  - `:account_id`
  - `:rng`
  - `:dispute_p` — probability of flagging per tick (default 0.02)
  - `:cancel_p` — probability of cancelling a freshly-flagged dispute (default 0.1)
  - `:tick_count`
  - `:flagged_market_ids` — markets this disputer has flagged
  """

  use GenServer

  require Logger

  alias PerpWalk.Identity.Facade, as: IdentityFacade
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Sim.Metrics

  @default_dispute_p 0.02
  @default_cancel_p 0.1

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # --- GenServer ---

  @impl true
  def init(opts) do
    seed = Keyword.fetch!(opts, :seed)

    {:ok, %{account_id: id}} = IdentityFacade.register()

    {:ok,
     %{
       account_id: id,
       rng: :rand.seed_s(:exsss, seed),
       dispute_p: Keyword.get(opts, :dispute_p, @default_dispute_p),
       cancel_p: Keyword.get(opts, :cancel_p, @default_cancel_p),
       tick_count: 0,
       flagged_market_ids: MapSet.new()
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    start_us = System.monotonic_time(:microsecond)

    state =
      state
      |> Map.update!(:tick_count, &(&1 + 1))
      |> maybe_flag()

    Metrics.incr({:actor, :disputer, :us}, System.monotonic_time(:microsecond) - start_us)
    Metrics.incr({:actor, :disputer, :ticks})

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Strategy ---

  defp maybe_flag(state) do
    {roll, rng} = :rand.uniform_s(state.rng)
    state = %{state | rng: rng}

    if roll < state.dispute_p do
      flag_one(state)
    else
      state
    end
  end

  defp flag_one(state) do
    candidates =
      MarketsFacade.list_markets_by_status(:resolving)
      |> Enum.reject(&MapSet.member?(state.flagged_market_ids, &1.id))

    case candidates do
      [] ->
        state

      markets ->
        {market, rng} = pick_random(markets, state.rng)

        case MarketsFacade.start_dispute(state.account_id, market.id) do
          {:ok, _dispute} ->
            Metrics.incr({:dispute, :filed})
            state = %{state | rng: rng, flagged_market_ids: MapSet.put(state.flagged_market_ids, market.id)}
            maybe_cancel(state, market.id)

          {:error, reason} ->
            Logger.debug("Disputer: flag failed, market=#{market.id}, reason=#{inspect(reason)}")
            %{state | rng: rng}
        end
    end
  end

  defp maybe_cancel(state, market_id) do
    {roll, rng} = :rand.uniform_s(state.rng)
    state = %{state | rng: rng}

    if roll < state.cancel_p do
      _ = MarketsFacade.cancel_dispute(state.account_id, market_id)
      Metrics.incr({:dispute, :cancelled})
      %{state | flagged_market_ids: MapSet.delete(state.flagged_market_ids, market_id)}
    else
      _ = MarketsFacade.confirm_dispute_deposit(state.account_id, market_id)
      Metrics.incr({:dispute, :live})
      state
    end
  end

  defp pick_random(list, rng) when is_list(list) and list != [] do
    {idx, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, idx - 1), rng}
  end
end
