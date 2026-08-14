defmodule PerpWalk.Sim.Scenarios.Deadlines do
  @moduledoc """
  Many simultaneous expirations. The default `Sim.Clock` setting
  compresses listing windows and resolution deadlines into
  seconds-scale, and this scenario uses that compression to
  funnel a burst of markets into the same expiry tick.

  Validates that `Markets.Scheduler` handles batched lifecycle
  transitions cleanly — many `:active → :expired` transitions
  in one tick, then many `:expired → :resolving` resolutions
  shortly after, then many `:resolving → :settled` settlements
  later. The CAS guards in `Store.put_resolution_cas` are
  exercised heavily under this load.
  """

  @behaviour PerpWalk.Sim.Scenarios.Scenario

  @defaults %{
    creators: 20,
    voters: 30,
    traders: 100,
    disputers: 5,
    guardians: 1,
    claimers: 2
  }

  @impl PerpWalk.Sim.Scenarios.Scenario
  def init(opts) do
    counts =
      @defaults
      |> Enum.map(fn {role, default} -> {role, Keyword.get(opts, role, default)} end)
      |> Map.new()

    actors = [
      # Burst-creator: high propose rate concentrated early so all
      # markets share an expiry window.
      %{role: :creator, count: counts.creators, opts: [propose_p: 0.4]},
      %{role: :voter, count: counts.voters, opts: [vote_p: 0.4]},
      %{role: :trader, count: counts.traders, opts: [trade_p: 0.3]},
      %{role: :disputer, count: counts.disputers, opts: []},
      %{role: :guardian, count: counts.guardians, opts: []},
      %{role: :claimer, count: counts.claimers, opts: []}
    ]

    {:ok, %{actors: actors, state: %{}}}
  end

  @impl PerpWalk.Sim.Scenarios.Scenario
  def on_tick(_now, _tick, state), do: {:ok, [], state}
end
