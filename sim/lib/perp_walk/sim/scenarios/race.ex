defmodule PerpWalk.Sim.Scenarios.Race do
  @moduledoc """
  Concurrent settle-vs-dispute pressure. Many traders fill up
  markets quickly, many disputers flag confirmed disputes
  rapidly — the goal is to hit the `Store.put_resolution_cas/3`
  guard often.

  ## Invariant coverage

  - `Concurrency` — the settle-vs-dispute CAS guard. Fires only
    if `put_resolution_cas` ever weakens (a `:live` dispute
    confirmed AFTER a market was settled).
  - `Creator.Economics` — seed-math check on every
    `MarketCreated`. High creator throughput at
    `propose_p: 0.3` × 10 creators means a fresh market lands
    almost every tick, and traders immediately hit it via
    `trade_p: 0.4` × 100 traders. Any window where a
    partially-seeded pool becomes tradeable would surface as
    `:seed_drift` on the FIRST trade.

  No scripted events — the high actor density and tight tick
  interval drive both races naturally.
  """

  @behaviour PerpWalk.Sim.Scenarios.Scenario

  @defaults %{
    creators: 10,
    voters: 20,
    traders: 100,
    disputers: 50,
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
      %{role: :creator, count: counts.creators, opts: [propose_p: 0.3]},
      %{role: :voter, count: counts.voters, opts: [vote_p: 0.5]},
      %{role: :trader, count: counts.traders, opts: [trade_p: 0.4]},
      %{role: :disputer, count: counts.disputers, opts: [dispute_p: 0.3, cancel_p: 0.0]},
      %{role: :guardian, count: counts.guardians, opts: [reverse_p: 0.5]},
      %{role: :claimer, count: counts.claimers, opts: []}
    ]

    {:ok, %{actors: actors, state: %{}}}
  end

  @impl PerpWalk.Sim.Scenarios.Scenario
  def on_tick(_now, _tick, state), do: {:ok, [], state}
end
