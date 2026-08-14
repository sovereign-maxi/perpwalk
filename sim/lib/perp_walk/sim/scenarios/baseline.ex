defmodule PerpWalk.Sim.Scenarios.Baseline do
  @moduledoc """
  Smoke-test scenario: well-behaved actors, full lifecycle, no
  scripted events.

  Used as the first sanity check that the harness composes
  correctly — markets get created, voted on, traded, resolved,
  disputed (rarely), settled, and claimed without invariant
  violations.

  ## Default actor mix

  - 5 honest creators
  - 20 honest voters
  - 50 honest traders
  - 10 honest disputers
  - 1 honest guardian
  - 1 claimer
  - 3 underpayers at low `:underpay_p` — routine baseline coverage
    of the auto-refund pipeline without materially changing the
    scenario's shape (small share of quotes end up refunded)

  Override via opts: `:creators`, `:voters`, `:traders`,
  `:disputers`, `:guardians`, `:claimers`, `:underpayers`,
  `:baseline_underpay_p`.
  """

  @behaviour PerpWalk.Sim.Scenarios.Scenario

  @defaults %{
    creators: 5,
    voters: 20,
    traders: 50,
    disputers: 10,
    guardians: 1,
    claimers: 1,
    underpayers: 3
  }

  # Low underpayment probability — enough to exercise the refund
  # pipeline once every ~30 baseline ticks per underpayer, but far
  # below the dedicated `Underpayment` scenario's rate so baseline
  # runs stay dominated by the happy path.
  @default_baseline_underpay_p 0.03

  @impl PerpWalk.Sim.Scenarios.Scenario
  def init(opts) do
    counts =
      @defaults
      |> Enum.map(fn {role, default} -> {role, Keyword.get(opts, role, default)} end)
      |> Map.new()

    underpay_p = Keyword.get(opts, :baseline_underpay_p, @default_baseline_underpay_p)

    actors = [
      %{role: :creator, count: counts.creators, opts: []},
      %{role: :voter, count: counts.voters, opts: []},
      %{role: :trader, count: counts.traders, opts: []},
      %{role: :disputer, count: counts.disputers, opts: []},
      %{role: :underpayer, count: counts.underpayers, opts: [underpay_p: underpay_p]},
      %{role: :guardian, count: counts.guardians, opts: []},
      %{role: :claimer, count: counts.claimers, opts: []}
    ]

    {:ok, %{actors: actors, state: %{}}}
  end

  @impl PerpWalk.Sim.Scenarios.Scenario
  def on_tick(_now, _tick, state), do: {:ok, [], state}
end
