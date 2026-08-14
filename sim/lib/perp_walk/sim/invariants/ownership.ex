defmodule PerpWalk.Sim.Invariants.Ownership do
  @moduledoc """
  Verifies every payout's `account_id` matches the owner of the
  underlying position or dispute.

  Event-driven: subscribes to `FederationEvents.PayoutRequested`
  and looks up the parent entity at the moment the payout is
  created. Mismatch → recorded violation. The earlier
  snapshot-scanning version checked every payout on every validate
  call (O(payouts) per tick); this version is O(1) per
  PayoutRequested event.

  Violation kinds:

  - `:position_owner_mismatch` — position payout where the
    payout's `account_id` differs from the position's owner.
  - `:unknown_position` — position payout whose `position_id`
    isn't in the store at event time.
  - `:unknown_dispute` — dispute refund whose `(account_id,
    market_id)` doesn't resolve to a dispute.

  `Cashier.ensure_owner` is supposed to prevent any of these from
  ever happening. The invariant catches a regression if that guard
  weakens.
  """

  use GenServer

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Markets.Facade, as: MarketsFacade

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Validator-contract check/1. Snapshot is ignored."
  @spec check(map()) :: :ok | {:violation, map()}
  def check(_snapshot) do
    case GenServer.call(__MODULE__, :snapshot) do
      [] ->
        :ok

      violations ->
        {:violation,
         %{
           kind: :ownership_mismatch,
           count: length(violations),
           sample: Enum.take(violations, 3)
         }}
    end
  end

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # --- GenServer ---

  @impl true
  def init(_opts) do
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
  def handle_info(
        %FederationEvents.PayoutRequested{
          request_id: rid,
          position_id: pid,
          account_id: aid,
          market_id: mid,
          kind: kind
        },
        state
      ) do
    {:noreply, check_ownership(state, rid, pid, aid, mid, kind)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp check_ownership(state, rid, _pid, aid, mid, kind)
       when kind in [:dispute_refund_full, :dispute_refund_partial] do
    case MarketsFacade.get_dispute(aid, mid) do
      {:ok, _dispute} ->
        state

      {:error, :not_found} ->
        record(
          state,
          rid,
          %{payout_id: rid, kind: :unknown_dispute, account_id: aid, market_id: mid}
        )
    end
  end

  defp check_ownership(state, rid, pid, aid, _mid, _kind) when is_binary(pid) do
    case MarketsFacade.get_position(pid) do
      {:ok, %{account_id: owner}} when owner == aid ->
        state

      {:ok, %{account_id: owner}} ->
        record(
          state,
          rid,
          %{
            payout_id: rid,
            kind: :position_owner_mismatch,
            payout_account: aid,
            position_owner: owner
          }
        )

      {:error, :not_found} ->
        record(
          state,
          rid,
          %{payout_id: rid, kind: :unknown_position, position_id: pid}
        )
    end
  end

  defp check_ownership(state, _rid, nil, _aid, _mid, _kind), do: state

  defp record(state, key, violation) do
    %{state | violations_by_key: Map.put(state.violations_by_key, key, violation)}
  end
end
