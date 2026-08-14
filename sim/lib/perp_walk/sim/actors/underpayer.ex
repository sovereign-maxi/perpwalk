defmodule PerpWalk.Sim.Actors.Underpayer do
  @moduledoc """
  Sim actor that intentionally short-pays a quote to exercise the
  underpayment auto-refund pipeline.

  Prod's `Monero.Poller` sees a confirmed on-chain deposit that
  falls short of the locked quote price, records an
  `:underpayment` orphan for audit, and calls
  `Federation.Facade.enqueue_quote_underpayment_refund/5` which
  routes back through the standard Rules → Sign → Broadcast path.
  This actor reproduces that sequence in sim without a real
  wallet:

  1. Pick an `:active` market at random.
  2. Create a fresh Quote via `MarketsFacade.create_quote/5`.
  3. Compute a shortfall (dust / small / large per strategy).
  4. Publish a `QuoteUnderpaid` event so any LiveView / consumer
     picks up the state transition.
  5. Record an `:underpayment` orphan (Poller sequence).
  6. Enqueue the refund via `Federation.Facade` (Poller sequence).
  7. Mark the orphan resolved on successful enqueue (Poller
     sequence).

  ## Shortfall distribution

  Weighted by `:shortfall_mix` opt (default 60/30/10):

  - `:small` — 1 piconero shy of expected. Refund succeeds; fee
    consumes most of the shortfall.
  - `:medium` — 25% shy. Refund succeeds cleanly; typical case.
  - `:dust` — 1 piconero total sent. Below fee. Signer will fail
    the refund at build time; PayoutFailed fires; Orphan should
    stay `:open` — that's the invariant coverage.

  ## State

  - `:account_id`
  - `:rng`
  - `:underpay_p` — probability of underpaying per tick (default 0.1)
  - `:shortfall_mix` — weighted picker for the shortfall size
  - `:tick_count`
  """

  use GenServer

  require Logger

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Identity.Facade, as: IdentityFacade
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Monero.Orphans
  alias PerpWalk.Sim.{Metrics, Subaddresses}

  @default_underpay_p 0.1
  @default_max_contracts 20
  @default_shortfall_mix [small: 60, medium: 30, dust: 10]

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
       underpay_p: Keyword.get(opts, :underpay_p, @default_underpay_p),
       max_contracts: Keyword.get(opts, :max_contracts, @default_max_contracts),
       shortfall_mix: Keyword.get(opts, :shortfall_mix, @default_shortfall_mix),
       tick_count: 0
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    start_us = System.monotonic_time(:microsecond)

    state =
      state
      |> Map.update!(:tick_count, &(&1 + 1))
      |> maybe_underpay()

    Metrics.incr({:actor, :underpayer, :us}, System.monotonic_time(:microsecond) - start_us)
    Metrics.incr({:actor, :underpayer, :ticks})

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Strategy ---

  defp maybe_underpay(state) do
    {roll, rng} = :rand.uniform_s(state.rng)
    state = %{state | rng: rng}

    if roll < state.underpay_p do
      run_underpayment(state)
    else
      state
    end
  end

  defp run_underpayment(state) do
    case MarketsFacade.list_markets_by_status(:active) do
      [] ->
        state

      markets ->
        {market, rng} = pick_random(markets, state.rng)
        {side, rng} = pick_random([:yes, :no], rng)
        {contracts, rng} = :rand.uniform_s(state.max_contracts, rng)
        {kind, rng} = pick_shortfall_kind(state.shortfall_mix, rng)

        state = %{state | rng: rng}

        case MarketsFacade.create_quote(state.account_id, market.id, side, contracts,
               refund_address: sim_refund_address()
             ) do
          {:ok, quote} ->
            simulate_underpayment(quote, kind)
            state

          {:error, reason} ->
            Logger.debug("Underpayer: quote failed, market=#{market.id}, reason=#{inspect(reason)}")
            Metrics.incr({:underpayer, :quote_failed})
            state
        end
    end
  end

  # Reproduces the Poller's underpaid-branch sequence verbatim.
  # Keep this in step with `PerpWalk.Monero.Poller.process_confirmed/4`
  # (`{:quote, id}` branch, underpayment case): Orphan record →
  # QuoteUnderpaid publish → refund enqueue → Orphan resolve on
  # success.
  defp simulate_underpayment(quote, kind) do
    expected = quote.amount_paid_piconeros
    amount = compute_underpaid_amount(expected, kind)
    txid = "sim-underpay-#{quote.id}-#{System.unique_integer([:positive])}"

    Metrics.incr({:underpayer, :simulated})
    Metrics.incr({:underpayer, kind})

    Orphans.record(:underpayment, txid, amount, %{quote_id: quote.id, paid: amount, expected: expected}, 2)

    EventBus.publish(%MarketsEvents.QuoteUnderpaid{
      quote_id: quote.id,
      market_id: quote.market_id,
      txid: txid,
      amount_paid_piconeros: amount,
      amount_expected_piconeros: expected,
      refund_address: quote.refund_address,
      timestamp: DateTime.utc_now()
    })

    case FederationFacade.enqueue_quote_underpayment_refund(
           quote.id,
           quote.account_id,
           quote.market_id,
           amount,
           quote.refund_address
         ) do
      {:ok, _payout} ->
        Metrics.incr({:underpayer, :refund_enqueued})
        Orphans.mark_resolved(txid)

      {:error, :quote_underpayment_refund_already_pending} ->
        Metrics.incr({:underpayer, :refund_already_pending})

      {:error, reason} ->
        Metrics.incr({:underpayer, :refund_enqueue_failed})
        Logger.debug("Underpayer: enqueue failed, quote=#{quote.id}, reason=#{inspect(reason)}")
    end
  end

  # 1 piconero short — small delta, refund succeeds, fee consumes
  # most of the remainder.
  defp compute_underpaid_amount(expected, :small), do: max(1, expected - 1)

  # 25% short — typical underpayment scenario, refund succeeds
  # cleanly.
  defp compute_underpaid_amount(expected, :medium), do: div(expected * 3, 4)

  # 1 piconero total — below any conceivable fee. Signer will fail
  # the refund; PayoutFailed fires; Orphan should stay `:open`.
  defp compute_underpaid_amount(_expected, :dust), do: 1

  defp pick_shortfall_kind(mix, rng) do
    total = Enum.reduce(mix, 0, fn {_k, w}, acc -> acc + w end)
    {roll, rng} = :rand.uniform_s(total, rng)

    kind =
      Enum.reduce_while(mix, {roll, nil}, fn {k, w}, {r, _} ->
        if r <= w, do: {:halt, {r, k}}, else: {:cont, {r - w, k}}
      end)
      |> elem(1)

    {kind, rng}
  end

  defp pick_random(list, rng) when is_list(list) and list != [] do
    {idx, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, idx - 1), rng}
  end

  defp sim_refund_address do
    {:ok, %{address: addr}} = Subaddresses.next()
    addr
  end
end
