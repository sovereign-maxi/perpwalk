defmodule PerpWalk.Monero.Supervisor do
  @moduledoc """
  Supervises the Monero domain.

  Children:
  - `PerpWalk.Monero.Poller` — bridges on-chain deposits to Markets
    quote fills. Conditional via `:perpwalk, :monero_poller,
    enabled: bool` so tests (and any deployment that wants the
    Facade without the poll loop) can opt out.

  The Finch HTTP pool used by `Darks.Client` is started at the
  application top level (`PerpWalk.Application`) and named
  `PerpWalk.Finch` — Tor proxy wiring lives there because outbound
  HTTP is an application-wide concern, not a Monero-domain one.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Budget raised from the OTP default (3 in 5s). The Poller bridges
    # the wallet RPC which can be flaky during sync or restart.
    Supervisor.init(children(), strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  defp children do
    base = [PerpWalk.Monero.Orphans]
    base = if multisig_scheduler_enabled?(), do: base ++ [PerpWalk.Monero.Multisig.Scheduler], else: base
    if poller_enabled?(), do: base ++ [PerpWalk.Monero.Poller], else: base
  end

  defp poller_enabled? do
    Application.get_env(:perpwalk, :monero_poller, [])
    |> Keyword.get(:enabled, true)
  end

  defp multisig_scheduler_enabled? do
    Application.get_env(:perpwalk, :monero, [])
    |> Keyword.get(:multisig_scheduler_enabled, true)
  end
end
