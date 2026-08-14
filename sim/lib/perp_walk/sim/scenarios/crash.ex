defmodule PerpWalk.Sim.Scenarios.Crash do
  @moduledoc """
  Crash-and-replay scenario.

  At configured ticks, kills a supervised store process and
  waits for the supervisor to restart it. The Markets.Store
  and Federation.Store both replay their respective WALs on
  init/1, so the kill+restart cycle is the production
  crash-recovery path under test.

  Pre-crash, the scenario snapshots entity counts via
  `Sim.Crash.snapshot/0`. Post-crash, it compares against
  current state via `Sim.Crash.compare/1` and surfaces the
  result through the Replay invariant. A `:count_decrease`
  diff means the WAL replay lost data — the central failure
  mode this scenario is designed to catch.

  ## Crash schedule

  Default: crash `:markets_store` at tick 80, `:federation_store`
  at tick 160. Override via `:markets_crash_at` and
  `:federation_crash_at` opts. Pace crashes well under the
  supervisor's `max_restarts: 10, max_seconds: 60` budget.
  """

  @behaviour PerpWalk.Sim.Scenarios.Scenario

  require Logger

  alias PerpWalk.Sim.Crash
  alias PerpWalk.Sim.Invariants.Replay

  @default_markets_crash_at 80
  @default_federation_crash_at 160

  @defaults %{
    creators: 5,
    voters: 20,
    traders: 50,
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
         markets_crash_at: Keyword.get(opts, :markets_crash_at, @default_markets_crash_at),
         federation_crash_at: Keyword.get(opts, :federation_crash_at, @default_federation_crash_at),
         pre_crash: nil
       }
     }}
  end

  @impl PerpWalk.Sim.Scenarios.Scenario
  def on_tick(_now, tick, state) do
    cond do
      tick == state.markets_crash_at ->
        do_crash(:markets_store, state)

      tick == state.federation_crash_at ->
        do_crash(:federation_store, state)

      true ->
        {:ok, [], state}
    end
  end

  # --- Internal ---

  defp do_crash(target, state) do
    pre = Crash.snapshot()

    case Crash.kill_and_wait(target) do
      :ok ->
        Logger.info("Crash: #{inspect(target)} restart complete, validating recovery")
        Replay.request_check()
        Replay.record_result(Crash.compare(pre))

      {:error, :timeout} ->
        Logger.error("Crash: #{inspect(target)} restart timed out")
        Replay.request_check()
        Replay.record_result({:mismatch, %{kind: :restart_timeout, target: target}})
    end

    {:ok, [], %{state | pre_crash: pre}}
  end
end
