defmodule Mix.Tasks.Sim.Events do
  @shortdoc "Run a PERP WALK events simulation"

  @moduledoc """
  Runs a sim against the events-domain stack.

  ## Usage

      mix sim.events --scenario baseline --ticks 600 --seed 42

  ## Options

      --scenario NAME   Scenario module short name (default: baseline)
      --ticks N         Total tick count (default: 600)
      --tick-ms N       Wall-clock ms per tick (default: 100)
      --seed N          RNG seed (default: random)
      --validate        Run invariant validators
      --validate-every N  Run validators every N ticks (default: 1 if
                          --validate is set). Trades coverage for speed
                          on long runs — invariants must hold at all
                          times, but checking every Nth tick still
                          catches violations because state persists.
      --report PATH     Write JSON report to PATH (otherwise stdout)
      --keep-data       Skip the default fresh-data wipe (rare; used
                          when investigating a WAL replay bug)
      --creators N      Override actor count (also: voters, traders,
                          disputers, guardians, claimers)

  ## Scenarios

      baseline          Honest actors, full lifecycle
      dishonesty        Creators write ambiguous criteria, resolve dishonestly
      spam              Sybil disputers spam-flag every resolution
      listings          Flood of low-quality market proposals
      deadlines         Many simultaneous expirations
      halt              Operator halts mid-flow
      race              Settle vs dispute concurrent race
      crash             Random process crashes mid-run

  Most scenarios beyond `baseline` are stubs in early sim builds —
  ship the harness, add scenarios incrementally.

  ## Fresh-data default

  Each invocation wipes the data directory before booting the
  application. Prior-run WAL entries, accumulated corrupt entries
  from killed runs, and stale ETS snapshots are otherwise replayed
  on boot — making each successive sim run progressively slower
  and obscuring the very behaviours the harness is meant to expose.
  `--keep-data` preserves the directory for the rare case of
  investigating WAL replay itself.
  """

  use Mix.Task

  alias PerpWalk.Sim.{Boot, Engine, Reporter}

  @switches [
    scenario: :string,
    ticks: :integer,
    tick_ms: :integer,
    seed: :integer,
    validate: :boolean,
    validate_every: :integer,
    report: :string,
    keep_data: :boolean,
    creators: :integer,
    voters: :integer,
    traders: :integer,
    disputers: :integer,
    guardians: :integer,
    claimers: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    unless Keyword.get(opts, :keep_data, false), do: Boot.wipe_data_dir!()
    Boot.suppress_web_endpoints!()
    Boot.install_overrides!()

    Mix.Task.run("app.start")

    scenario = scenario_module(Keyword.get(opts, :scenario, "baseline"))
    seed = Keyword.get(opts, :seed, :rand.uniform(1_000_000_000))

    scenario_opts =
      Keyword.take(opts, [:creators, :voters, :traders, :disputers, :guardians, :claimers])

    summary =
      Engine.run(
        scenario: scenario,
        scenario_opts: scenario_opts,
        seed: seed,
        ticks: Keyword.get(opts, :ticks, 600),
        tick_interval_ms: Keyword.get(opts, :tick_ms, 100),
        validate: Keyword.get(opts, :validate, false),
        validate_every: Keyword.get(opts, :validate_every, 1)
      )

    output(summary, Keyword.get(opts, :report))
  end

  # --- Internal ---

  defp scenario_module(name) do
    case name do
      "baseline" -> PerpWalk.Sim.Scenarios.Baseline
      "dishonesty" -> PerpWalk.Sim.Scenarios.Dishonesty
      "spam" -> PerpWalk.Sim.Scenarios.Spam
      "listings" -> PerpWalk.Sim.Scenarios.Listings
      "deadlines" -> PerpWalk.Sim.Scenarios.Deadlines
      "halt" -> PerpWalk.Sim.Scenarios.Halt
      "race" -> PerpWalk.Sim.Scenarios.Race
      "crash" -> PerpWalk.Sim.Scenarios.Crash
      "adversarial" -> PerpWalk.Sim.Scenarios.Adversarial
      "underpayment" -> PerpWalk.Sim.Scenarios.Underpayment
      "federation_income" -> PerpWalk.Sim.Scenarios.Federation.Income
      "processor_failover" -> PerpWalk.Sim.Scenarios.Processor.Failover

      other ->
        raise "Unknown scenario: #{other}. Available: baseline, dishonesty, spam, listings, deadlines, halt, race, crash, adversarial, underpayment, federation_income, processor_failover"
    end
  end

  defp output(summary, nil) do
    Mix.shell().info(Reporter.to_json!(summary))
  end

  defp output(summary, path) when is_binary(path) do
    File.write!(path, Reporter.to_json!(summary))
    Mix.shell().info("Report written to #{path}")
  end

end
