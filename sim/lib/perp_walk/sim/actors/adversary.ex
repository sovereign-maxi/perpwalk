defmodule PerpWalk.Sim.Actors.Adversary do
  @moduledoc """
  Adversarial creator: proposes markets like the honest creator,
  but at resolution time picks the outcome that hurts the
  majority of traders.

  Drives the actual bad-faith resolution attack vector:

  1. Creator proposes a market.
  2. Voters approve, market activates, traders open positions.
  3. Most volume ends up on one side (say YES has 100 contracts,
     NO has 20).
  4. At expiry, creator resolves NO — making the YES holders
     lose. The dispute window opens.
  5. Disputers should detect the malicious resolution and stake
     dispute claims. If enough cross the threshold, guardians
     reverse the resolution.

  Validates the central guarantee of the dispute system:
  dishonest resolutions get reversed.

  Strategy parameters:

  - `:propose_p` — propose probability per tick (default 0.05)
  - `:malice_p` — when resolving, probability of picking the
    losing-for-majority outcome. 1.0 = always adversarial,
    0.0 = honest (degenerates to honest Creator). Default 0.8.
  """

  use GenServer

  require Logger

  alias PerpWalk.Identity.Facade, as: IdentityFacade
  alias PerpWalk.Markets.Categories
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Sim.Clock
  alias PerpWalk.Sim.Metrics

  @default_propose_p 0.05
  @default_malice_p 0.8

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
       propose_p: Keyword.get(opts, :propose_p, @default_propose_p),
       malice_p: Keyword.get(opts, :malice_p, @default_malice_p),
       tick_count: 0,
       created_market_ids: []
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    start_us = System.monotonic_time(:microsecond)

    state =
      state
      |> Map.update!(:tick_count, &(&1 + 1))
      |> maybe_propose()
      |> resolve_expired()

    Metrics.incr({:actor, :adversary, :us}, System.monotonic_time(:microsecond) - start_us)
    Metrics.incr({:actor, :adversary, :ticks})

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Strategy ---

  defp maybe_propose(state) do
    {roll, rng} = :rand.uniform_s(state.rng)
    state = %{state | rng: rng}

    if roll < state.propose_p do
      propose(state)
    else
      state
    end
  end

  defp propose(state) do
    {category, rng} = pick_random(Categories.all(), state.rng)
    {n, rng} = :rand.uniform_s(100_000, rng)

    expiry = DateTime.add(DateTime.utc_now(), Clock.compress(86_400 * 7), :second)

    opts = [
      description: "Adversarial sim market #{n}",
      resolution_criterion:
        "Resolves YES if a deliberately ambiguous condition holds at deadline; otherwise NO.",
      category: category,
      expiry: expiry,
      creator_account_id: state.account_id
    ]

    case MarketsFacade.create_market(opts) do
      {:ok, market} ->
        _ = MarketsFacade.confirm_market_deposit(market.id)
        Metrics.incr({:market, :created_adversarial})
        %{state | rng: rng, created_market_ids: [market.id | state.created_market_ids]}

      {:error, _reason} ->
        %{state | rng: rng}
    end
  end

  defp resolve_expired(state) do
    Enum.reduce(state.created_market_ids, state, &maybe_resolve/2)
  end

  defp maybe_resolve(market_id, state) do
    case MarketsFacade.get_market(market_id) do
      {:ok, %{status: :expired}} ->
        {outcome, rng} = adversarial_outcome(market_id, state.rng, state.malice_p)

        case MarketsFacade.submit_resolution(state.account_id, market_id, outcome) do
          {:ok, _} ->
            Metrics.incr({:resolution, :adversarial})
            %{state | rng: rng}

          {:error, reason} ->
            Logger.debug("Adversary: resolve failed, market=#{market_id}, reason=#{inspect(reason)}")
            %{state | rng: rng}
        end

      _ ->
        state
    end
  end

  # Picks the outcome that hurts the majority of position holders.
  # With probability `malice_p` we pick adversarially; otherwise
  # fall back to honest 50/50 so the scenario isn't comically
  # detectable.
  defp adversarial_outcome(market_id, rng, malice_p) do
    {roll, rng} = :rand.uniform_s(rng)

    if roll < malice_p do
      case majority_side(market_id) do
        :yes -> {:no, rng}
        :no -> {:yes, rng}
        :tie -> pick_random([:yes, :no], rng)
      end
    else
      pick_random([:yes, :no], rng)
    end
  end

  # Returns `:yes` / `:no` / `:tie` based on which side holds
  # more position value. The "majority" perspective means: if
  # users staked more on YES, resolving NO maximally hurts them.
  defp majority_side(market_id) do
    positions =
      market_id
      |> MarketsFacade.list_positions_for_market()
      |> Enum.filter(&(&1.status == :open))

    yes_value = positions |> Enum.filter(&(&1.side == :yes)) |> Enum.map(& &1.amount_paid) |> Enum.sum()
    no_value = positions |> Enum.filter(&(&1.side == :no)) |> Enum.map(& &1.amount_paid) |> Enum.sum()

    cond do
      yes_value > no_value -> :yes
      no_value > yes_value -> :no
      true -> :tie
    end
  end

  defp pick_random(list, rng) when is_list(list) and list != [] do
    {idx, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, idx - 1), rng}
  end
end
