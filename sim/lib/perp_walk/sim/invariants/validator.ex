defmodule PerpWalk.Sim.Invariants.Validator do
  @moduledoc """
  Runs every invariant module each invocation and accumulates
  violations.

  Each invariant exposes `check/1 :: (snapshot) -> :ok |
  {:violation, term()}`. All invariants are now either
  event-driven (Lifecycle, Idempotency, Ownership, Uniqueness,
  Conservation) or read via indexed store calls (Concurrency,
  Halt, Replay, Replication). None of them require a pre-built
  state snapshot, so `check/1` receives `nil` and ignores it.
  Per-validate cost is the sum of nine cheap `GenServer.call`s
  plus a couple of indexed lookups — no per-tick full-table folds.

  ## Adding an invariant

  Implement a module under `PerpWalk.Sim.Invariants.<Name>` with
  `check/1`. Add it to `@invariants` below. Snapshot-based
  invariants are no longer supported; new invariants should
  accumulate state via `PerpWalk.Events.EventBus` subscriptions
  or read indexed store data directly inside `check/1`.
  """

  alias PerpWalk.Sim.Metrics

  @invariants [
    PerpWalk.Sim.Invariants.Conservation,
    PerpWalk.Sim.Invariants.Lifecycle,
    PerpWalk.Sim.Invariants.Ownership,
    PerpWalk.Sim.Invariants.Uniqueness,
    PerpWalk.Sim.Invariants.Idempotency,
    PerpWalk.Sim.Invariants.Replay,
    PerpWalk.Sim.Invariants.Concurrency,
    PerpWalk.Sim.Invariants.Halt,
    PerpWalk.Sim.Invariants.Replication,
    PerpWalk.Sim.Invariants.Reserves,
    PerpWalk.Sim.Invariants.Payout.Pipeline,
    PerpWalk.Sim.Invariants.Orphans,
    PerpWalk.Sim.Invariants.Creator.Economics
  ]

  @type violation :: {module(), term()}

  # --- Public API ---

  @doc """
  Runs every configured invariant. Returns the accumulated list
  of violations across all invariants.
  """
  @spec validate() :: [violation()]
  def validate do
    task = Task.async(&run_validation/0)
    Task.await(task, :infinity)
  end

  defp run_validation do
    Enum.reduce(@invariants, [], fn invariant, acc ->
      Metrics.incr({:invariant, short_name(invariant), :checks})

      {dt_us, result} = :timer.tc(fn -> invariant.check(nil) end)
      Metrics.incr({:invariant, short_name(invariant), :us}, dt_us)

      case result do
        :ok ->
          acc

        {:violation, details} ->
          Metrics.incr({:invariant, short_name(invariant), :violations})
          [{invariant, details} | acc]
      end
    end)
    |> Enum.reverse()
  end

  @doc "Returns the configured invariant module list."
  @spec invariants() :: [module()]
  def invariants, do: @invariants

  # --- Internal ---

  defp short_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> String.downcase()
    |> String.to_atom()
  end
end
