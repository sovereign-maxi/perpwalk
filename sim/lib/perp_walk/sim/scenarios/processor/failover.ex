defmodule PerpWalk.Sim.Scenarios.Processor.Failover do
  @moduledoc """
  Exercises runtime designated-processor promotion mid-flight.

  In a homogeneous federation only one node writes cluster state
  at a time — the "designated processor" (usually `:p1`). Every
  other node observes on-chain events locally but skips the
  cluster-write branch, receiving state via WAL replication.
  Runtime promotion via `Federation.Console.promote_processor/1`
  moves the write role at operator command without a redeploy.

  ## Timeline (single-node, default tick counts)

  - Ticks 0..`:promote_at`: baseline activity, `:p1` is
    designated. `Role.designated_processor?/0` returns `true` and
    writes flow.
  - Tick `:promote_at`: promote to `:p2`. This node is no longer
    designated; new confirmations from the Poller stop advancing
    cluster state.
  - Ticks `:promote_at..:demote_at`: quiescent window. Positions
    and market transitions should NOT advance from this node
    (they would in a multi-node cluster arrive via replication —
    unavailable in single-node sim).
  - Tick `:demote_at`: promote back to `:p1`. Writes resume.

  ## Coverage

  - `Console.promote_processor/1` accepts a valid participant_id
    and flips the runtime env cleanly.
  - `Role.designated_processor?/0` reads the flipped value
    consistently.
  - No invariant regression during the flip windows — the state
    is quiescent, not corrupted.

  ## What this DOESN'T cover

  - Multi-node WAL replication of writes from the new
    designated processor. Would need a multi-node sim.
  - Peer RPC failure paths in `Console.promote_processor/1`
    (`:partial` return). Single-node has no peers to fail.
  """

  @behaviour PerpWalk.Sim.Scenarios.Scenario

  require Logger

  alias PerpWalk.Federation.Console

  @defaults %{
    creators: 3,
    voters: 15,
    traders: 30,
    disputers: 5,
    guardians: 1,
    claimers: 1
  }

  @default_promote_at 100
  @default_demote_at 200

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
      %{role: :disputer, count: counts.disputers, opts: []},
      %{role: :guardian, count: counts.guardians, opts: []},
      %{role: :claimer, count: counts.claimers, opts: []}
    ]

    {:ok,
     %{
       actors: actors,
       state: %{
         promote_at: Keyword.get(opts, :promote_at, @default_promote_at),
         demote_at: Keyword.get(opts, :demote_at, @default_demote_at),
         promotions: 0,
         demotions: 0
       }
     }}
  end

  @impl PerpWalk.Sim.Scenarios.Scenario
  def on_tick(_now, tick, state) do
    cond do
      tick == state.promote_at ->
        result = Console.promote_processor(:p2)
        Logger.info("Processor.Failover: promoted to :p2, result=#{inspect(result)}")
        {:ok, [], %{state | promotions: state.promotions + 1}}

      tick == state.demote_at ->
        result = Console.promote_processor(:p1)
        Logger.info("Processor.Failover: demoted back to :p1, result=#{inspect(result)}")
        {:ok, [], %{state | demotions: state.demotions + 1}}

      true ->
        {:ok, [], state}
    end
  end
end
