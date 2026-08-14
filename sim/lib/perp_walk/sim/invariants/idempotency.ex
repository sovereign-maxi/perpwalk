defmodule PerpWalk.Sim.Invariants.Idempotency do
  @moduledoc """
  Verifies no entity ends up with multiple non-terminal payouts in
  flight at once. Event-driven: subscribes to FederationEvents.*
  and tracks the set of in-flight payout ids per scope
  (`{:position, position_id}` for winner / refund payouts,
  `{:dispute, account_id, market_id}` for dispute refunds).

  - On `PayoutRequested` the new payout id is added to its scope's
    set. If the set already held a different id at that moment a
    violation is recorded.
  - On `PayoutFailed` the failed payout id is removed from the set
    so a legitimate retry doesn't trigger a false positive.
  - `:paid_out` is one-shot by definition (the underlying position
    transitions to `:paid_out` and refuses further `claim_payout`
    calls), so we don't need a dedicated event to drain its set
    entry.

  The earlier snapshot-scanning version walked every payout on
  every validate call, group-by'd them, and flagged scopes with
  > 1 non-terminal entries — O(payouts) per tick. The event-driven
  version costs O(1) per relevant event and O(violations) at
  validate time.
  """

  use GenServer

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents

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
           kind: :idempotency_event_driven,
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
    EventBus.subscribe(FederationEvents.PayoutFailed)

    {:ok,
     %{
       # scope_key => MapSet of in-flight payout ids
       in_flight: %{},
       # violation_key => violation map (dedup by scope)
       violations_by_key: %{}
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.values(state.violations_by_key), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | in_flight: %{}, violations_by_key: %{}}}
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
    scope = scope_for(kind, pid, aid, mid)
    {:noreply, record_in_flight(state, scope, rid)}
  end

  def handle_info(%FederationEvents.PayoutFailed{request_id: rid}, state) do
    {:noreply, drop_payout(state, rid)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp scope_for(kind, _pid, aid, mid)
       when kind in [:dispute_refund_full, :dispute_refund_partial],
       do: {:dispute, aid, mid}

  defp scope_for(_kind, pid, _aid, _mid) when is_binary(pid), do: {:position, pid}

  defp scope_for(_kind, _pid, _aid, _mid), do: nil

  defp record_in_flight(state, nil, _rid), do: state

  defp record_in_flight(state, scope, rid) do
    current = Map.get(state.in_flight, scope, MapSet.new())
    updated = MapSet.put(current, rid)

    state = %{state | in_flight: Map.put(state.in_flight, scope, updated)}

    if MapSet.size(updated) > 1 do
      record_violation(state, scope, updated)
    else
      state
    end
  end

  defp drop_payout(state, rid) do
    in_flight =
      state.in_flight
      |> Enum.map(fn {scope, set} -> {scope, MapSet.delete(set, rid)} end)
      |> Enum.reject(fn {_scope, set} -> MapSet.size(set) == 0 end)
      |> Map.new()

    %{state | in_flight: in_flight}
  end

  defp record_violation(state, scope, in_flight_set) do
    violation =
      case scope do
        {:position, pid} ->
          %{
            kind: :double_position_payout,
            position_id: pid,
            count: MapSet.size(in_flight_set),
            payout_ids: MapSet.to_list(in_flight_set)
          }

        {:dispute, aid, mid} ->
          %{
            kind: :double_dispute_refund,
            dispute_key: {aid, mid},
            count: MapSet.size(in_flight_set),
            payout_ids: MapSet.to_list(in_flight_set)
          }
      end

    %{state | violations_by_key: Map.put(state.violations_by_key, scope, violation)}
  end
end
