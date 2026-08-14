defmodule PerpWalk.Sim.Run do
  @moduledoc """
  Process-independent run-context handle.

  The engine records the run's start timestamp here so invariant
  modules can filter their checks to entities created during the
  current run, ignoring leftover WAL state from prior dev or test
  sessions. Backed by `:persistent_term` so any process reads
  the same value without GenServer roundtrips.

  Set once at engine start; cleared on engine teardown.
  """

  @start_key {__MODULE__, :start_time}

  @doc "Records the run-start timestamp. Called by `Sim.Engine.prepare/1`."
  @spec mark_started() :: DateTime.t()
  def mark_started do
    now = DateTime.utc_now()
    :persistent_term.put(@start_key, now)
    now
  end

  @doc "Clears the run-start marker. Called by `Sim.Engine.finalise/1`."
  @spec mark_finished() :: :ok
  def mark_finished do
    _ = :persistent_term.erase(@start_key)
    :ok
  end

  @doc """
  Returns the current run's start timestamp, or `~U[1970-01-01 00:00:00Z]`
  when no sim is active. Invariants treat the unix-epoch fallback
  as "match everything" so non-sim contexts still pass.
  """
  @spec start_time() :: DateTime.t()
  def start_time, do: :persistent_term.get(@start_key, ~U[1970-01-01 00:00:00Z])

  @doc """
  Predicate: was `dt` recorded after the current run started?
  Invariants pass entities through this filter to avoid flagging
  leftover state from prior runs.
  """
  @spec from_current_run?(DateTime.t() | nil) :: boolean()
  def from_current_run?(nil), do: false

  def from_current_run?(%DateTime{} = dt) do
    DateTime.compare(dt, start_time()) != :lt
  end
end
