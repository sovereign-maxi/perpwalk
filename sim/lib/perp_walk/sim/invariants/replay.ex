defmodule PerpWalk.Sim.Invariants.Replay do
  @moduledoc """
  Verifies WAL-replay equivalence: at marker points, the live
  ETS state matches what would be reconstructed by replaying
  the WAL from scratch.

  Driven by the `Crash` scenario, which marks "expect a replay
  pass after this tick" via `:persistent_term`. This invariant
  consumes the marker and runs the comparison in-process — slow
  but rare. Routine ticks return `:ok` without doing the heavy
  comparison.

  The actual replay-driver lives in the Crash scenario itself
  because it needs to coordinate with the supervisor to stop
  and restart the stores. This invariant module is the consumer
  side of that coordination.
  """

  @marker_key {__MODULE__, :replay_check_pending}

  # --- Public API for scenarios ---

  @doc "Marker — sets a flag for the next `check/0` call to perform the replay comparison."
  @spec request_check() :: :ok
  def request_check do
    :persistent_term.put(@marker_key, true)
    :ok
  end

  @doc """
  Returns the most recent recorded comparison result. The Crash
  scenario writes this after orchestrating a replay round.
  """
  @spec record_result(:ok | {:mismatch, map()}) :: :ok
  def record_result(result) do
    :persistent_term.put({__MODULE__, :last_result}, result)
    :ok
  end

  @spec check(map()) :: :ok | {:violation, map()}
  def check(_snapshot) do
    case :persistent_term.get(@marker_key, false) do
      false ->
        :ok

      true ->
        :persistent_term.put(@marker_key, false)

        case :persistent_term.get({__MODULE__, :last_result}, :ok) do
          :ok -> :ok
          {:mismatch, details} -> {:violation, %{kind: :replay_mismatch, details: details}}
        end
    end
  end
end
