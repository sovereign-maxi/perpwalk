defmodule PerpWalk.Sim.Invariants.Halt do
  @moduledoc """
  Verifies the federation halt boundary: while
  `Federation.Signer.halted?/0` is true, no payout request
  transitions out of `:pending` or `:rules_passed` toward the
  signing pipeline.

  Implementation:

  - On scenario halt-marker, `take_snapshot/0` records the
    pre-halt set of in-flight payout statuses.
  - On scenario resume-marker, `verify_no_progress/0` re-reads
    in-flight statuses and confirms no payout advanced past its
    pre-halt status during the halt window.
  - `check/0` returns the most recent comparison; routine
    ticks (no halt active) return `:ok`.

  The Halt scenario drives the markers; this invariant module
  is the consumer side.
  """

  alias PerpWalk.Federation.Facade, as: FederationFacade

  @snapshot_key {__MODULE__, :pre_halt_snapshot}
  @result_key {__MODULE__, :last_result}

  # --- Public API for scenarios ---

  @doc "Records the in-flight payout statuses just before halting."
  @spec take_snapshot() :: :ok
  def take_snapshot do
    snapshot =
      FederationFacade.list_in_flight_requests()
      |> Map.new(&{&1.id, &1.status})

    :persistent_term.put(@snapshot_key, snapshot)
    :ok
  end

  @doc """
  Compares current in-flight statuses against the pre-halt
  snapshot. If any request advanced toward signing during the
  halt, records a violation; otherwise records `:ok`.
  """
  @spec verify_no_progress() :: :ok
  def verify_no_progress do
    case :persistent_term.get(@snapshot_key, nil) do
      nil ->
        :persistent_term.put(@result_key, :ok)
        :ok

      snapshot ->
        progressed =
          FederationFacade.list_in_flight_requests()
          |> Enum.flat_map(fn req ->
            case Map.get(snapshot, req.id) do
              nil -> []
              prior when prior == req.status -> []
              prior -> [%{request_id: req.id, before: prior, after: req.status}]
            end
          end)

        result =
          if progressed == [] do
            :ok
          else
            {:progressed_during_halt, progressed}
          end

        :persistent_term.put(@result_key, result)
        :persistent_term.erase(@snapshot_key)
        :ok
    end
  end

  @spec check(map()) :: :ok | {:violation, map()}
  def check(_snapshot) do
    case :persistent_term.get(@result_key, :ok) do
      :ok ->
        :ok

      {:progressed_during_halt, details} ->
        :persistent_term.put(@result_key, :ok)
        {:violation, %{kind: :progressed_during_halt, count: length(details), sample: Enum.take(details, 3)}}
    end
  end
end
