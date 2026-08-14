defmodule PerpWalk.Sim.Actors.Guardian do
  @moduledoc """
  Sim actor that plays the federation guardian role.

  Honest guardian strategy:
  - Each tick, scan `:resolving` markets where live disputes have
    crossed the review threshold. With probability
    `:reverse_p` (default 0.3), reverse the resolution; otherwise
    acknowledge the existing one. This roughly models guardians
    siding with disputers 30% of the time when they review.

  This actor is intentionally singular per run — the federation
  has one combined judgement under sim. Multi-guardian
  coordination (split votes, threshold reach) is exercised by
  the federation runtime itself, not modelled here.

  ## State

  - `:account_id` — guardians don't really have an account_id
    in the protocol sense, but we register one for symmetry
  - `:rng`
  - `:reverse_p` — probability of reversing a reviewed market
  - `:tick_count`
  - `:reviewed_market_ids` — markets this guardian has acted on
  """

  use GenServer

  require Logger

  alias PerpWalk.Identity.Facade, as: IdentityFacade
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Markets.Moderation
  alias PerpWalk.Sim.Metrics

  @default_reverse_p 0.3

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
       reverse_p: Keyword.get(opts, :reverse_p, @default_reverse_p),
       tick_count: 0,
       reviewed_market_ids: MapSet.new()
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    start_us = System.monotonic_time(:microsecond)

    state =
      state
      |> Map.update!(:tick_count, &(&1 + 1))
      |> review_pending()

    Metrics.incr({:actor, :guardian, :us}, System.monotonic_time(:microsecond) - start_us)
    Metrics.incr({:actor, :guardian, :ticks})

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Strategy ---

  defp review_pending(state) do
    threshold = Moderation.default_dispute_threshold()

    MarketsFacade.list_markets_by_status(:resolving)
    |> Enum.reject(&MapSet.member?(state.reviewed_market_ids, &1.id))
    |> Enum.filter(fn m ->
      live = MarketsFacade.live_dispute_count(m.id)
      live >= threshold and live > m.disputes_acknowledged_count
    end)
    |> Enum.reduce(state, &review_one/2)
  end

  defp review_one(market, state) do
    {roll, rng} = :rand.uniform_s(state.rng)

    result =
      if roll < state.reverse_p do
        new_outcome = if market.outcome == :yes, do: :no, else: :yes

        case MarketsFacade.reverse_resolution(market.id, new_outcome) do
          {:ok, _} ->
            Metrics.incr({:guardian, :reversed})
            :ok

          {:error, reason} ->
            Logger.debug("Guardian: reverse failed, market=#{market.id}, reason=#{inspect(reason)}")
            :error
        end
      else
        case MarketsFacade.acknowledge_disputes(market.id) do
          {:ok, _} ->
            Metrics.incr({:guardian, :acknowledged})
            :ok

          {:error, reason} ->
            Logger.debug("Guardian: ack failed, market=#{market.id}, reason=#{inspect(reason)}")
            :error
        end
      end

    case result do
      :ok -> %{state | rng: rng, reviewed_market_ids: MapSet.put(state.reviewed_market_ids, market.id)}
      :error -> %{state | rng: rng}
    end
  end
end
