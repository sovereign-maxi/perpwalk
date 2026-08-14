defmodule PerpWalk.Sim.Scenarios.Underpayment do
  @moduledoc """
  Stresses the underpayment auto-refund pipeline.

  A pool of `Underpayer` actors runs against a normal honest mix
  of creators + voters + guardians + claimers. Each Underpayer
  tick, at `:underpay_p` probability, opens a quote and reproduces
  the `Monero.Poller` underpaid-branch sequence — record orphan,
  publish `QuoteUnderpaid`, enqueue refund via `Federation.Facade`,
  mark orphan resolved on successful enqueue.

  ## Invariant coverage this exercises

  - `PayoutPipeline` — every enqueued `:quote_underpayment_refund`
    must reach a terminal state.
  - `Orphans` — every `:open` `:underpayment` orphan without a
    matching enqueued refund past the threshold is a violation.
    Dust underpayments are expected to fail the Signer's build
    step and leave the orphan open — the Orphan invariant's
    `stuck_threshold_checks` needs to be tuned above the number
    of checks a Signer failure takes, or the dust cases will
    flag legitimately.
  - `Idempotency` — repeated underpayments to the same quote
    must not enqueue duplicate refunds (Store's uniqueness scope
    on `source_quote_id` is the enforcement).

  ## Default actor mix

  Minimal honest crew to keep markets flowing, plus 20 dedicated
  Underpayers so the refund pipeline gets steady traffic.

  Override via opts: `:creators`, `:voters`, `:traders`,
  `:underpayers`, `:guardians`, `:claimers`, `:underpay_p`.
  """

  @behaviour PerpWalk.Sim.Scenarios.Scenario

  @defaults %{
    creators: 3,
    voters: 15,
    traders: 20,
    underpayers: 20,
    guardians: 1,
    claimers: 1
  }

  @default_underpay_p 0.3

  @impl PerpWalk.Sim.Scenarios.Scenario
  def init(opts) do
    counts =
      @defaults
      |> Enum.map(fn {role, default} -> {role, Keyword.get(opts, role, default)} end)
      |> Map.new()

    underpay_p = Keyword.get(opts, :underpay_p, @default_underpay_p)

    actors = [
      %{role: :creator, count: counts.creators, opts: []},
      %{role: :voter, count: counts.voters, opts: []},
      %{role: :trader, count: counts.traders, opts: []},
      %{role: :underpayer, count: counts.underpayers, opts: [underpay_p: underpay_p]},
      %{role: :guardian, count: counts.guardians, opts: []},
      %{role: :claimer, count: counts.claimers, opts: []}
    ]

    {:ok, %{actors: actors, state: %{}}}
  end

  @impl PerpWalk.Sim.Scenarios.Scenario
  def on_tick(_now, _tick, state), do: {:ok, [], state}
end
