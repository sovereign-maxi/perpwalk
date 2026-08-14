defmodule PerpWalk.Sim.Scenarios.Listings do
  @moduledoc """
  Floods the venue with market proposals. Creators run with a
  high `:propose_p` while voters lean heavily downvote, so the
  burn-on-rejection moderation gets exercised at scale.

  Validates:
  - Conservation: every rejected market's deposit lands in
    operator income (`burned_piconeros`).
  - Lifecycle: `:rejected` markets stay `:rejected` and are
    never resurrected.
  - The community-moderation path scales — the listing-vote
    table holds up under many concurrent voters.
  """

  @behaviour PerpWalk.Sim.Scenarios.Scenario

  @defaults %{
    creators: 30,
    voters: 50,
    traders: 10,
    disputers: 2,
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
      %{role: :creator, count: counts.creators, opts: [propose_p: 0.5]},
      %{role: :voter, count: counts.voters, opts: [vote_p: 0.5, up_bias: 0.2]},
      %{role: :trader, count: counts.traders, opts: []},
      %{role: :disputer, count: counts.disputers, opts: []},
      %{role: :guardian, count: counts.guardians, opts: []},
      %{role: :claimer, count: counts.claimers, opts: []}
    ]

    {:ok, %{actors: actors, state: %{}}}
  end

  @impl PerpWalk.Sim.Scenarios.Scenario
  def on_tick(_now, _tick, state), do: {:ok, [], state}
end
