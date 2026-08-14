defmodule PerpWalk.Sim.Scenarios.Spam do
  @moduledoc """
  Sybil dispute spam: many disputers, each with very high
  per-tick dispute probability, with a high cancel rate.

  Validates two things:
  1. The cancel-on-close path scales — many `:awaiting_deposit`
     records get created and cancelled rapidly without orphaning
     the dispute counter or creating subaddress collisions.
  2. The slash math holds when many disputes resolve to
     `:resolved_for` simultaneously (Conservation invariant).
  """

  @behaviour PerpWalk.Sim.Scenarios.Scenario

  @defaults %{
    creators: 3,
    voters: 10,
    traders: 30,
    disputers: 100,
    guardians: 1,
    claimers: 1
  }

  @impl PerpWalk.Sim.Scenarios.Scenario
  def init(opts) do
    counts =
      @defaults
      |> Enum.map(fn {role, default} -> {role, Keyword.get(opts, role, default)} end)
      |> Map.new()

    actors = [
      %{role: :creator, count: counts.creators, opts: []},
      %{role: :voter, count: counts.voters, opts: []},
      %{role: :trader, count: counts.traders, opts: []},
      %{role: :disputer, count: counts.disputers, opts: [dispute_p: 0.5, cancel_p: 0.5]},
      %{role: :guardian, count: counts.guardians, opts: []},
      %{role: :claimer, count: counts.claimers, opts: []}
    ]

    {:ok, %{actors: actors, state: %{}}}
  end

  @impl PerpWalk.Sim.Scenarios.Scenario
  def on_tick(_now, _tick, state), do: {:ok, [], state}
end
