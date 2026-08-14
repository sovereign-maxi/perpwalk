defmodule PerpWalk.Telemetry.Supervisor do
  @moduledoc """
  Supervises the Telemetry subsystems.

  Start order matters: Cache populates the data alerts read; the
  Manager evaluates rules; the System aggregates active alerts into
  a status; the Ring takes periodic snapshots. `one_for_one` so a
  single component crash doesn't take the whole tree down.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      PerpWalk.Telemetry.Health.Cache,
      PerpWalk.Telemetry.Alerts.Manager,
      PerpWalk.Telemetry.Health.System,
      PerpWalk.Telemetry.Metrics.Ring,
      PerpWalk.Telemetry.Publishers.Nostr
    ]

    # Budget raised from the OTP default (3 in 5s). Telemetry
    # publishers can fail transiently on Nostr relay flakiness; the
    # OTP default would cascade those into the root supervisor.
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end
end
