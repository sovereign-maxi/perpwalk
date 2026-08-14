defmodule PerpWalk.Sim.Actors.Trader do
  @moduledoc """
  Sim actor that opens positions on `:active` markets via the
  AMM.

  Honest trader strategy:
  - Each tick, with probability `:trade_p`, scan `:active`
    markets, pick one at random, choose `:yes` or `:no` at
    50/50, and open a position via the quote+fill flow.
    The sim immediately confirms the quote's deposit (matches
    the Creator/Disputer pattern).

  ## State

  - `:account_id`
  - `:rng`
  - `:trade_p` — probability of trading per tick (default 0.2)
  - `:max_contracts` — upper bound on per-trade size (default 50)
  - `:tick_count`
  """

  use GenServer

  require Logger

  alias PerpWalk.Identity.Facade, as: IdentityFacade
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Sim.{Metrics, Subaddresses}

  @default_trade_p 0.2
  @default_max_contracts 50

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
       trade_p: Keyword.get(opts, :trade_p, @default_trade_p),
       max_contracts: Keyword.get(opts, :max_contracts, @default_max_contracts),
       tick_count: 0
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    start_us = System.monotonic_time(:microsecond)

    state =
      state
      |> Map.update!(:tick_count, &(&1 + 1))
      |> maybe_trade()

    Metrics.incr({:actor, :trader, :us}, System.monotonic_time(:microsecond) - start_us)
    Metrics.incr({:actor, :trader, :ticks})

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Strategy ---

  defp maybe_trade(state) do
    {roll, rng} = :rand.uniform_s(state.rng)
    state = %{state | rng: rng}

    if roll < state.trade_p do
      open_one_position(state)
    else
      state
    end
  end

  defp open_one_position(state) do
    case MarketsFacade.list_markets_by_status(:active) do
      [] ->
        state

      markets ->
        {market, rng} = pick_random(markets, state.rng)
        {side, rng} = pick_random([:yes, :no], rng)
        {contracts, rng} = :rand.uniform_s(state.max_contracts, rng)

        case MarketsFacade.create_quote(state.account_id, market.id, side, contracts,
               refund_address: sim_refund_address()
             ) do
          {:ok, quote} ->
            # Sim shortcut: confirm the quote's deposit immediately
            # by filling it, replacing the on-chain confirmation
            # path the production Poller would drive.
            case MarketsFacade.fill_quote(quote.id) do
              {:ok, _position} ->
                Metrics.incr({:position, :opened})
                %{state | rng: rng}

              {:error, reason} ->
                Logger.debug("Trader: fill failed, quote=#{quote.id}, reason=#{inspect(reason)}")
                Metrics.incr({:position, :fill_failed})
                %{state | rng: rng}
            end

          {:error, reason} ->
            Logger.debug("Trader: quote failed, market=#{market.id}, reason=#{inspect(reason)}")
            Metrics.incr({:position, :quote_failed})
            %{state | rng: rng}
        end
    end
  end

  defp pick_random(list, rng) when is_list(list) and list != [] do
    {idx, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, idx - 1), rng}
  end

  # Sim uses the same generator as deposit subaddresses — same
  # base58 encoding, same mainnet regex acceptance. In prod the
  # user types this at trade time; in sim we bake a fresh one per
  # quote so nothing surfaces as `:refund_address_required` on
  # every call. Address is discarded after the quote fills — the
  # underpayment scenario is what exercises the refund pipeline.
  defp sim_refund_address do
    {:ok, %{address: addr}} = Subaddresses.next()
    addr
  end
end
