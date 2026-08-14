defmodule PerpWalk.Sim.Actors.Voter do
  @moduledoc """
  Sim actor that votes on `:pending` markets in the listing
  window.

  Honest voter strategy:
  - Each tick, with probability `:vote_p`, scan `:pending`
    markets the actor hasn't already voted on, pick one at
    random, and cast `:up` (probability `:up_bias`, default 0.7)
    or `:down`.

  Sybil downvoter and other adversarial variants are separate
  modules so each strategy module stays focused.

  ## State

  - `:account_id`
  - `:rng`
  - `:vote_p` — probability of voting per tick (default 0.1)
  - `:up_bias` — probability the cast is `:up` when voting (default 0.7)
  - `:tick_count`
  - `:voted_market_ids` — local cache to avoid pointless `:already_voted` calls
  """

  use GenServer

  require Logger

  alias PerpWalk.Identity.Facade, as: IdentityFacade
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Sim.Metrics

  @default_vote_p 0.1
  @default_up_bias 0.7

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
       vote_p: Keyword.get(opts, :vote_p, @default_vote_p),
       up_bias: Keyword.get(opts, :up_bias, @default_up_bias),
       tick_count: 0,
       voted_market_ids: MapSet.new()
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    start_us = System.monotonic_time(:microsecond)

    state =
      state
      |> Map.update!(:tick_count, &(&1 + 1))
      |> maybe_vote()

    Metrics.incr({:actor, :voter, :us}, System.monotonic_time(:microsecond) - start_us)
    Metrics.incr({:actor, :voter, :ticks})

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Strategy ---

  defp maybe_vote(state) do
    {roll, rng} = :rand.uniform_s(state.rng)
    state = %{state | rng: rng}

    if roll < state.vote_p do
      cast_one_vote(state)
    else
      state
    end
  end

  defp cast_one_vote(state) do
    pending =
      MarketsFacade.list_markets_by_status(:pending)
      |> Enum.reject(fn m ->
        m.creator_account_id == state.account_id or
          MapSet.member?(state.voted_market_ids, m.id)
      end)

    case pending do
      [] ->
        state

      candidates ->
        {market, rng} = pick_random(candidates, state.rng)
        {direction, rng} = pick_direction(rng, state.up_bias)

        case MarketsFacade.cast_vote(state.account_id, market.id, direction) do
          {:ok, _} ->
            Metrics.incr({:vote, direction})

            %{
              state
              | rng: rng,
                voted_market_ids: MapSet.put(state.voted_market_ids, market.id)
            }

          {:error, reason} ->
            Logger.debug("Voter: vote failed, market=#{market.id}, reason=#{inspect(reason)}")
            %{state | rng: rng}
        end
    end
  end

  defp pick_direction(rng, up_bias) do
    {roll, rng} = :rand.uniform_s(rng)
    direction = if roll < up_bias, do: :up, else: :down
    {direction, rng}
  end

  defp pick_random(list, rng) when is_list(list) and list != [] do
    {idx, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, idx - 1), rng}
  end
end
