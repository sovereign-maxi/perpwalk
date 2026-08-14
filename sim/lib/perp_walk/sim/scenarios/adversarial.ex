defmodule PerpWalk.Sim.Scenarios.Adversarial do
  @moduledoc """
  Bad-faith resolution attack scenario.

  Replaces the honest Creator with `Sim.Actors.Adversary`, which
  examines positions on each `:expired` market and resolves to
  the outcome that hurts the majority of traders. Disputers and
  guardians are dialled up so the dispute pipeline gets a real
  workout.

  Validates the central guarantee of the dispute system: a
  creator who deliberately resolves dishonestly cannot get
  away with it — the dispute threshold is crossed, the
  guardian reverses, and disputers get refunded.

  ## Defaults

  - 5 adversaries
  - 30 traders (so volume accumulates fast)
  - 30 disputers with high `:dispute_p`
  - 1 guardian with `:reverse_p` 0.7 (sides with disputers
    most of the time, modelling honest review)

  ## Validating success

  After a run, expect:
  - Many `:resolution_reversed` events (dispute pipeline
    catching adversaries)
  - Slashed creator deposits showing in `federation_ledger.burned`
    (the slash side of reversal — currently this is dispute
    slashes from disputers losing on honest reverse-resolution
    events; adversarial creator deposit-slashes are a separate
    domain feature not yet wired)
  - All invariants pass (no double-payouts, no orphans)
  """

  @behaviour PerpWalk.Sim.Scenarios.Scenario

  @defaults %{
    adversaries: 5,
    voters: 20,
    traders: 30,
    disputers: 30,
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
      %{role: :adversary, count: counts.adversaries, opts: [propose_p: 0.1, malice_p: 0.9]},
      %{role: :voter, count: counts.voters, opts: [vote_p: 0.3, up_bias: 0.8]},
      %{role: :trader, count: counts.traders, opts: [trade_p: 0.3]},
      %{role: :disputer, count: counts.disputers, opts: [dispute_p: 0.3, cancel_p: 0.05]},
      %{role: :guardian, count: counts.guardians, opts: [reverse_p: 0.7]},
      %{role: :claimer, count: counts.claimers, opts: []}
    ]

    {:ok, %{actors: actors, state: %{}}}
  end

  @impl PerpWalk.Sim.Scenarios.Scenario
  def on_tick(_now, _tick, state), do: {:ok, [], state}
end
