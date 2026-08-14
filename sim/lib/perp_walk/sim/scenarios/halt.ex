defmodule PerpWalk.Sim.Scenarios.Halt do
  @moduledoc """
  Drives `Federation.Signer` halt/resume to validate that
  in-flight payouts pause during halt and resume cleanly
  afterward — no lost work, no double-progression.

  Scenario timeline (in ticks):

  - Ticks 0..N: baseline activity, payouts queue.
  - Tick `:halt_at`: emit `:halt` event. The Halt invariant
    snapshots in-flight payout statuses.
  - Ticks `:halt_at..:resume_at`: signer is halted, no
    payouts should advance.
  - Tick `:resume_at`: emit `:resume`, then the Halt invariant
    verifies no payout transitioned during the window.
  - Remaining ticks: normal operation, payouts drain.

  ## Payout kinds covered

  `Halt.take_snapshot/0` iterates every non-terminal payout via
  `FederationFacade.list_in_flight_requests/0` — kind-agnostic,
  so `:winner_payout`, `:refund`, `:dispute_refund_*`,
  `:creator_lp_return`, `:federation_income`, AND
  `:quote_underpayment_refund` are all snapshot-and-verified.
  A dedicated pool of `Underpayer` actors runs alongside the
  baseline mix so the refund pipeline actually has traffic
  in-flight when the halt fires.

  Defaults assume a 200-tick run; adjust via opts if running
  with a different `--ticks`.
  """

  @behaviour PerpWalk.Sim.Scenarios.Scenario

  alias PerpWalk.Sim.Invariants.Halt, as: HaltInvariant

  @default_halt_at 50
  @default_resume_at 100

  @defaults %{
    creators: 5,
    voters: 20,
    traders: 50,
    disputers: 5,
    underpayers: 10,
    guardians: 1,
    claimers: 2
  }

  # Higher than Baseline's 0.03 so refund payouts are landing
  # steadily by the time `:halt_at` fires — Halt's guarantee
  # only matters if there's actually pipeline traffic to freeze.
  @default_halt_underpay_p 0.15

  @impl PerpWalk.Sim.Scenarios.Scenario
  def init(opts) do
    counts =
      @defaults
      |> Enum.map(fn {role, default} -> {role, Keyword.get(opts, role, default)} end)
      |> Map.new()

    underpay_p = Keyword.get(opts, :halt_underpay_p, @default_halt_underpay_p)

    actors = [
      %{role: :creator, count: counts.creators, opts: []},
      %{role: :voter, count: counts.voters, opts: []},
      %{role: :trader, count: counts.traders, opts: []},
      %{role: :disputer, count: counts.disputers, opts: []},
      %{role: :underpayer, count: counts.underpayers, opts: [underpay_p: underpay_p]},
      %{role: :guardian, count: counts.guardians, opts: []},
      %{role: :claimer, count: counts.claimers, opts: []}
    ]

    {:ok,
     %{
       actors: actors,
       state: %{
         halt_at: Keyword.get(opts, :halt_at, @default_halt_at),
         resume_at: Keyword.get(opts, :resume_at, @default_resume_at)
       }
     }}
  end

  @impl PerpWalk.Sim.Scenarios.Scenario
  def on_tick(_now, tick, state) do
    cond do
      tick == state.halt_at ->
        HaltInvariant.take_snapshot()
        {:ok, [:halt], state}

      tick == state.resume_at ->
        HaltInvariant.verify_no_progress()
        {:ok, [:resume], state}

      true ->
        {:ok, [], state}
    end
  end
end
