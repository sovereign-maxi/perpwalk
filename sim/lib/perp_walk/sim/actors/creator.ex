defmodule PerpWalk.Sim.Actors.Creator do
  @moduledoc """
  Sim actor that proposes markets and resolves its own at expiry.

  Honest creator strategy:
  - Each tick, with probability `:propose_p`, proposes a fresh
    market with random category, compressed expiry/deadline, and
    a default deposit. Confirms its own deposit immediately
    (sim shortcut — replaces the on-chain confirmation path).
  - Each tick, scans its own `:expired` markets and resolves them
    with a random `:yes`/`:no` outcome. Honest doesn't favour
    either side.

  Dishonest variants override the resolution step to write
  ambiguous criteria or resolve against the volume — that's a
  separate actor module so each strategy stays small.

  ## State

  - `:account_id` — identity, registered at init
  - `:rng` — per-actor RNG, seeded
  - `:propose_p` — probability of proposing per tick (default 0.05)
  - `:tick_count`
  - `:created_market_ids` — markets this creator owns (for resolution scan)
  """

  use GenServer

  require Logger

  alias PerpWalk.Identity.Facade, as: IdentityFacade
  alias PerpWalk.Markets.Categories
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Sim.Clock
  alias PerpWalk.Sim.Metrics

  @default_propose_p 0.05

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns the actor's account_id (test/debug affordance)."
  @spec account_id(GenServer.server()) :: binary()
  def account_id(pid), do: GenServer.call(pid, :account_id)

  # --- GenServer ---

  @impl true
  def init(opts) do
    seed = Keyword.fetch!(opts, :seed)
    propose_p = Keyword.get(opts, :propose_p, @default_propose_p)

    {:ok, %{account_id: id}} = IdentityFacade.register()

    {:ok,
     %{
       account_id: id,
       rng: :rand.seed_s(:exsss, seed),
       propose_p: propose_p,
       tick_count: 0,
       created_market_ids: []
     }}
  end

  @impl true
  def handle_call(:account_id, _from, state), do: {:reply, state.account_id, state}

  @impl true
  def handle_info(:tick, state) do
    start_us = System.monotonic_time(:microsecond)

    state =
      state
      |> Map.update!(:tick_count, &(&1 + 1))
      |> maybe_propose()
      |> resolve_expired()

    Metrics.incr({:actor, :creator, :us}, System.monotonic_time(:microsecond) - start_us)
    Metrics.incr({:actor, :creator, :ticks})

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
      description: "Sim market #{n}: will outcome #{n} happen by deadline?",
      resolution_criterion:
        "Resolves YES if the deterministic sim oracle for outcome #{n} returns YES at deadline; otherwise NO.",
      category: category,
      expiry: expiry,
      creator_account_id: state.account_id
    ]

    case MarketsFacade.create_market(opts) do
      {:ok, market} ->
        # Sim shortcut: skip the Monero confirmation loop and mark
        # the deposit confirmed immediately. Keeps the actor focused
        # on lifecycle behaviour rather than on-chain timing.
        _ = MarketsFacade.confirm_market_deposit(market.id)
        Metrics.incr({:market, :created})
        %{state | rng: rng, created_market_ids: [market.id | state.created_market_ids]}

      {:error, reason} ->
        Logger.debug("Creator: propose failed, account=#{state.account_id}, reason=#{inspect(reason)}")
        Metrics.incr({:market, :propose_failed})
        %{state | rng: rng}
    end
  end

  defp resolve_expired(state) do
    Enum.reduce(state.created_market_ids, state, &maybe_resolve/2)
  end

  defp maybe_resolve(market_id, state) do
    case MarketsFacade.get_market(market_id) do
      {:ok, %{status: :expired}} ->
        {outcome, rng} = pick_random([:yes, :no], state.rng)

        case MarketsFacade.submit_resolution(state.account_id, market_id, outcome) do
          {:ok, _} ->
            Metrics.incr({:resolution, :submitted})
            %{state | rng: rng}

          {:error, reason} ->
            Logger.debug("Creator: resolve failed, market=#{market_id}, reason=#{inspect(reason)}")
            %{state | rng: rng}
        end

      _ ->
        state
    end
  end

  defp pick_random(list, rng) when is_list(list) and list != [] do
    {idx, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, idx - 1), rng}
  end
end
