defmodule PerpWalk.Sim.Scenarios.Dishonesty do
  @moduledoc """
  Stresses the dispute machinery by raising the dispute rate
  significantly relative to baseline. Validates that staked
  disputes resolve correctly under load, slash math holds
  across many concurrent resolutions, and the federation
  guardian path stays consistent.

  The honest Disputer's `:dispute_p` is 0.02 by default. This
  scenario bumps it to 0.2 (10× more disputes per tick) while
  also increasing the disputer count, so a meaningful fraction
  of resolutions get challenged.

  Run with `--validate` to confirm the conservation, idempotency,
  and ownership invariants hold under the elevated dispute rate.
  """

  @behaviour PerpWalk.Sim.Scenarios.Scenario

  @defaults %{
    creators: 5,
    voters: 20,
    traders: 50,
    disputers: 30,
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
      %{role: :disputer, count: counts.disputers, opts: [dispute_p: 0.2, cancel_p: 0.05]},
      %{role: :guardian, count: counts.guardians, opts: []},
      %{role: :claimer, count: counts.claimers, opts: []}
    ]

    {:ok, %{actors: actors, state: %{}}}
  end

  @impl PerpWalk.Sim.Scenarios.Scenario
  def on_tick(_now, _tick, state), do: {:ok, [], state}
end
