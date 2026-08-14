defmodule PerpWalk.Storage.Supervisor do
  @moduledoc false

  use Supervisor

  alias PerpWalk.Storage.{Checkpointer, Holder, Paths, Runner, WAL}
  alias PerpWalk.Storage.Replication.Nonces
  alias PerpWalk.Storage.WAL.Sealer
  alias PerpWalk.Telemetry.Health.System, as: HealthSystem

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Ensure all data subdirectories exist with 0o700 perms before any
    # child tries to write.
    Paths.ensure_dirs!()

    # Restore a persisted manual halt (if any) into `:persistent_term`
    # BEFORE any write-path can execute. An operator-declared halt
    # must survive a BEAM restart or the halt semantics are broken.
    HealthSystem.load_persisted_halt()

    children = [
      Holder,
      WAL,
      # Sealer starts AFTER WAL because it scans the WAL on init for
      # the global max seq. It starts BEFORE the domain stores
      # (Markets.Store, Federation.Store, Identity.Sessions) — which
      # are children of their own supervisors started later in the
      # application tree — so all WAL writes from those stores can
      # go through the Sealer from the first write onward.
      Sealer,
      Runner,
      Checkpointer,
      Nonces
    ]

    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end
end
