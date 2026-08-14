defmodule PerpWalk.Sim.Supervisor do
  @moduledoc """
  Top-level supervisor for sim-only infrastructure.

  Children:

  - `Subaddresses` — deterministic-but-unique subaddress allocator
    used by Markets services when `:subaddress_provider` is
    configured to a sim entry (dev / test / sim runs).
  - `Metrics` — flat counter/timer collector consumed by the
    validator and reporter.
  - Event-driven invariants — `Lifecycle`, `Idempotency`,
    `Ownership`, `Uniqueness`. Each subscribes to the relevant
    `PerpWalk.Events.*` topics on init, so they must start *after*
    `Phoenix.PubSub` is available. This supervisor is intended to
    be started by the main application supervisor as a final
    child (appended via the `:extra_children` config key), which
    guarantees PubSub is already up.

  Lives under `sim/lib/` which is excluded from `:prod`
  elixirc_paths, so production releases neither compile nor run
  this module.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      PerpWalk.Sim.Subaddresses,
      PerpWalk.Sim.Metrics,
      PerpWalk.Sim.Invariants.Lifecycle,
      PerpWalk.Sim.Invariants.Idempotency,
      PerpWalk.Sim.Invariants.Ownership,
      PerpWalk.Sim.Invariants.Uniqueness,
      PerpWalk.Sim.Invariants.Conservation,
      PerpWalk.Sim.Invariants.Payout.Pipeline,
      PerpWalk.Sim.Invariants.Orphans,
      PerpWalk.Sim.Invariants.Creator.Economics
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
