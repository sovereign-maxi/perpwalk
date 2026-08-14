defmodule PerpWalk.Sim.Actors.Claimer do
  @moduledoc """
  Sim actor that withdraws payouts on settled positions, resolved
  disputes, and creator LP returns on settled/voided markets.

  This actor doesn't have its own positions — it scans the
  global state for any winnable position, refundable dispute, or
  unclaimed creator LP return belonging to *any* sim account and
  submits a claim. Real users claim their own balances; for sim
  purposes, having a single Claimer drive all withdrawals exercises
  the federation signing pipeline without each Trader / Disputer /
  Creator having to duplicate the claim logic.

  Honest claimer strategy:
  - Each tick, look up positions in `:settled_winner` or
    `:refunded` (indexed) and disputes in `:resolved_for` or
    `:resolved_against` (indexed). For each that the actor has
    not yet attempted to claim, submit a claim using a
    deterministic sim destination address.
  - Also scan markets in `:settled` or `:voided` with
    `creator_lp_paid_out_at: nil` and submit the creator LP return
    on behalf of the market's creator. Covers the post-pivot
    economics where the creator's deposit IS the pool seed and
    earns residual on settle / full refund on void.
  - Once an attempt has been made (whether the Cashier returned
    `{:ok, _}` or `{:error, :*_already_pending}`), the entity
    is added to an `attempted` MapSet so subsequent ticks skip
    it. Without this dedup the actor was redoing tens of thousands
    of Cashier round-trips per tick once state had grown.

  ## State

  - `:account_id` — registered for symmetry
  - `:rng`
  - `:tick_count`
  - `:attempted_positions` — `MapSet<position_id>`
  - `:attempted_disputes` — `MapSet<{account_id, market_id}>`
  - `:attempted_lp_returns` — `MapSet<market_id>`
  """

  use GenServer

  require Logger

  alias PerpWalk.Identity.Facade, as: IdentityFacade
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Sim.Metrics

  # Valid Monero-format payout destination, deterministic across
  # runs so the report shows clean payouts with one consistent
  # address. Doesn't actually receive funds — sim never touches
  # real wallet RPC.
  @sim_destination "8" <> String.duplicate("A", 94)

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
       tick_count: 0,
       attempted_positions: MapSet.new(),
       attempted_disputes: MapSet.new(),
       attempted_lp_returns: MapSet.new()
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    start_us = System.monotonic_time(:microsecond)

    state =
      state
      |> Map.update!(:tick_count, &(&1 + 1))
      |> claim_payable_positions()
      |> claim_resolved_disputes()
      |> claim_creator_lp_returns()

    Metrics.incr({:actor, :claimer, :us}, System.monotonic_time(:microsecond) - start_us)
    Metrics.incr({:actor, :claimer, :ticks})

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Strategy ---

  defp claim_payable_positions(state) do
    candidates =
      MarketsFacade.list_positions_by_status(:settled_winner) ++
        MarketsFacade.list_positions_by_status(:refunded)

    new_attempts =
      Enum.reduce(candidates, state.attempted_positions, fn pos, attempted ->
        if MapSet.member?(attempted, pos.id) do
          attempted
        else
          case MarketsFacade.claim_payout(pos.id, pos.account_id, @sim_destination) do
            {:ok, _request} ->
              Metrics.incr({:payout, :requested})

            {:error, :payout_already_pending} ->
              :ok

            {:error, reason} ->
              Logger.debug("Claimer: position claim failed, position=#{pos.id}, reason=#{inspect(reason)}")
          end

          MapSet.put(attempted, pos.id)
        end
      end)

    %{state | attempted_positions: new_attempts}
  end

  defp claim_resolved_disputes(state) do
    candidates =
      MarketsFacade.list_disputes_by_status(:resolved_against) ++
        MarketsFacade.list_disputes_by_status(:resolved_for)

    new_attempts =
      Enum.reduce(candidates, state.attempted_disputes, fn dispute, attempted ->
        key = {dispute.account_id, dispute.market_id}

        if MapSet.member?(attempted, key) do
          attempted
        else
          case MarketsFacade.claim_dispute_refund(dispute.account_id, dispute.market_id, @sim_destination) do
            {:ok, _request} ->
              Metrics.incr({:payout, :dispute_refund_requested})

            {:error, :refund_already_pending} ->
              :ok

            {:error, reason} ->
              Logger.debug(
                "Claimer: dispute claim failed, account=#{dispute.account_id}, market=#{dispute.market_id}, reason=#{inspect(reason)}"
              )
          end

          MapSet.put(attempted, key)
        end
      end)

    %{state | attempted_disputes: new_attempts}
  end

  # Settled markets owe the creator their residual on the winning
  # side; voided markets owe the full deposit back. The Cashier
  # short-circuits if `creator_lp_paid_out_at` has already been
  # stamped (Federation has already broadcast on-chain), so the
  # local MapSet is only there to avoid hammering Cashier with
  # known-pending requests inside one sim run.
  defp claim_creator_lp_returns(state) do
    candidates =
      MarketsFacade.list_markets_by_status(:settled) ++
        MarketsFacade.list_markets_by_status(:voided)

    new_attempts =
      Enum.reduce(candidates, state.attempted_lp_returns, fn market, attempted ->
        cond do
          MapSet.member?(attempted, market.id) ->
            attempted

          # Already paid out — nothing to claim. Mark attempted so
          # we don't keep re-checking on every tick.
          not is_nil(market.creator_lp_paid_out_at) ->
            MapSet.put(attempted, market.id)

          # Voided markets where the creator was a no-show have no
          # deposit to return (the deposit was burned to house on
          # rejection-class voids). `lp_return_amount/1` returns 0;
          # skip those rather than enqueue a zero-piconero payout.
          MarketsFacade.creator_lp_return_amount(market) == 0 ->
            MapSet.put(attempted, market.id)

          true ->
            case MarketsFacade.claim_creator_lp_return(market.creator_account_id, market.id, @sim_destination) do
              {:ok, _request} ->
                Metrics.incr({:payout, :creator_lp_return_requested})

              {:error, :lp_return_already_pending} ->
                :ok

              {:error, :already_paid_out} ->
                :ok

              {:error, :market_not_returnable} ->
                :ok

              {:error, reason} ->
                Logger.debug(
                  "Claimer: creator LP claim failed, market=#{market.id}, reason=#{inspect(reason)}"
                )
            end

            MapSet.put(attempted, market.id)
        end
      end)

    %{state | attempted_lp_returns: new_attempts}
  end
end
