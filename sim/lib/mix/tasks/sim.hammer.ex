defmodule Mix.Tasks.Sim.Hammer do
  @shortdoc "Multi-tier PERP WALK sim progression: smoke → per-scenario → load → soak → seed sweep"

  @moduledoc """
  Runs the full 5-tier hammering plan and produces one aggregated
  report. Progresses only if the previous tier passed — the first
  violation aborts the run so operator attention lands on the
  earliest reproducer.

  ## Tiers

      1. Smoke        — Baseline, short run, sanity check
      2. Per-scenario — Each scenario individually at moderate load
      3. Load 5x      — Each scenario at 5× actor counts
      4. Soak         — Baseline for a long run (drift detection)
      5. Seed sweep   — Each scenario × N random seeds (statistical)

  ## Usage

      mix sim.hammer                # full progression, all tiers
      mix sim.hammer --tier smoke   # single tier
      mix sim.hammer --skip-soak    # skip long-running tiers
      mix sim.hammer --report PATH  # write JSON aggregate report

  ## Options

      --tier NAME       Run only one tier (smoke | per-scenario | load |
                        soak | seed-sweep). Default: run all sequentially.
      --skip-soak       Skip the 4th (soak) tier.
      --skip-seed-sweep Skip the 5th (seed sweep) tier.
      --seeds N         Seed count for seed sweep (default: 25).
      --report PATH     Write JSON aggregate report to PATH.
      --stop-on-fail    Abort at the first violation (default: true).

  ## Design notes

  Each tier calls `PerpWalk.Sim.Engine.run/1` directly rather than
  shelling out to `mix sim.events`. Every scenario run resets the
  entire application state (stop → wipe data dir → restart) so
  Markets.Store ETS, WAL, subaddress counters, and reserves history
  start clean per run — the invariant model assumes an isolated
  run, and cross-run pollution would surface as false-positive
  subaddress collisions plus a monotonically slowing Store.
  """

  use Mix.Task

  alias PerpWalk.Sim.{Boot, Engine}

  @all_scenarios [
    {"baseline", PerpWalk.Sim.Scenarios.Baseline},
    {"adversarial", PerpWalk.Sim.Scenarios.Adversarial},
    {"dishonesty", PerpWalk.Sim.Scenarios.Dishonesty},
    {"spam", PerpWalk.Sim.Scenarios.Spam},
    {"listings", PerpWalk.Sim.Scenarios.Listings},
    {"deadlines", PerpWalk.Sim.Scenarios.Deadlines},
    {"halt", PerpWalk.Sim.Scenarios.Halt},
    {"race", PerpWalk.Sim.Scenarios.Race},
    {"crash", PerpWalk.Sim.Scenarios.Crash},
    {"underpayment", PerpWalk.Sim.Scenarios.Underpayment},
    {"federation_income", PerpWalk.Sim.Scenarios.Federation.Income},
    {"processor_failover", PerpWalk.Sim.Scenarios.Processor.Failover}
  ]

  @switches [
    tier: :string,
    skip_soak: :boolean,
    skip_seed_sweep: :boolean,
    seeds: :integer,
    report: :string,
    stop_on_fail: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    # CRITICAL: prepare BEFORE the first `app.start`. Without this,
    # the initial boot brings up the full production supervision
    # tree — both Phoenix endpoints (user + admin), their esbuild
    # watchers, LiveReload, code reloader, the production signing
    # backend (which fails to reach monero-wallet-rpc and populates
    # retry state + writes failure WAL entries), and the production
    # reserves source. `reset_app_state!/0` calls `Boot.prepare!()`
    # before subsequent boots, but the initial polluted boot leaks
    # TIME_WAIT ports, orphaned :persistent_term entries, and
    # unrecognised WAL entries that surface as signing failures +
    # WAL replay errors in later runs.
    Boot.prepare!()
    Mix.Task.run("app.start")

    stop_on_fail = Keyword.get(opts, :stop_on_fail, true)

    tiers_to_run = tiers_from_opts(opts)

    Mix.shell().info("Sim.Hammer: tiers=#{inspect(tiers_to_run)}, stop_on_fail=#{stop_on_fail}")

    {results, _} =
      Enum.reduce_while(tiers_to_run, {[], :ok}, fn tier, {acc, _prev} ->
        tier_result = run_tier(tier, opts)

        acc = [tier_result | acc]

        if stop_on_fail and not tier_result.passed do
          Mix.shell().error("Sim.Hammer: tier=#{tier} FAILED, halting progression")
          {:halt, {acc, :fail}}
        else
          {:cont, {acc, :ok}}
        end
      end)

    aggregate = build_aggregate(Enum.reverse(results))
    emit_summary(aggregate)

    case Keyword.get(opts, :report) do
      nil -> :ok
      path -> File.write!(path, Jason.encode!(aggregate, pretty: true))
    end

    if aggregate.overall_passed, do: :ok, else: exit({:shutdown, 1})
  end

  # --- Tier resolution ---

  defp tiers_from_opts(opts) do
    all = [:smoke, :per_scenario, :load, :soak, :seed_sweep]

    cond do
      tier = Keyword.get(opts, :tier) -> [String.to_existing_atom(String.replace(tier, "-", "_"))]
      Keyword.get(opts, :skip_soak, false) and Keyword.get(opts, :skip_seed_sweep, false) ->
        all -- [:soak, :seed_sweep]
      Keyword.get(opts, :skip_soak, false) -> all -- [:soak]
      Keyword.get(opts, :skip_seed_sweep, false) -> all -- [:seed_sweep]
      true -> all
    end
  end

  # --- Tier drivers ---

  defp run_tier(:smoke, _opts) do
    Mix.shell().info("Sim.Hammer: [1/5] SMOKE — Baseline sanity")

    result =
      execute_run("baseline", PerpWalk.Sim.Scenarios.Baseline, seed: 1, ticks: 500, tick_ms: 5)

    %{tier: :smoke, runs: [result], passed: result.passed}
  end

  defp run_tier(:per_scenario, _opts) do
    Mix.shell().info("Sim.Hammer: [2/5] PER-SCENARIO — each scenario at moderate load")

    runs =
      Enum.map(@all_scenarios, fn {name, module} ->
        execute_run(name, module, seed: 1_000, ticks: 1_000, tick_ms: 5)
      end)

    %{tier: :per_scenario, runs: runs, passed: Enum.all?(runs, & &1.passed)}
  end

  defp run_tier(:load, _opts) do
    Mix.shell().info("Sim.Hammer: [3/5] LOAD 5x — high actor density")

    load_opts = [
      creators: 25,
      voters: 100,
      traders: 250,
      disputers: 50,
      guardians: 5,
      claimers: 5
    ]

    runs =
      Enum.map(@all_scenarios, fn {name, module} ->
        execute_run(name, module, seed: 2_000, ticks: 500, tick_ms: 5, scenario_opts: load_opts)
      end)

    %{tier: :load, runs: runs, passed: Enum.all?(runs, & &1.passed)}
  end

  defp run_tier(:soak, _opts) do
    Mix.shell().info("Sim.Hammer: [4/5] SOAK — Baseline, long run, drift detection")

    result =
      execute_run("baseline", PerpWalk.Sim.Scenarios.Baseline,
        seed: 3_000,
        ticks: 20_000,
        tick_ms: 2
      )

    %{tier: :soak, runs: [result], passed: result.passed}
  end

  defp run_tier(:seed_sweep, opts) do
    seeds = Keyword.get(opts, :seeds, 25)
    Mix.shell().info("Sim.Hammer: [5/5] SEED SWEEP — #{seeds} seeds per scenario")

    seed_list = for _ <- 1..seeds, do: :rand.uniform(1_000_000_000)

    runs =
      for {name, module} <- @all_scenarios,
          seed <- seed_list do
        execute_run(name, module, seed: seed, ticks: 300, tick_ms: 5)
      end

    %{tier: :seed_sweep, runs: runs, passed: Enum.all?(runs, & &1.passed)}
  end

  # --- One-run harness ---

  defp execute_run(name, module, opts) do
    seed = Keyword.fetch!(opts, :seed)
    ticks = Keyword.fetch!(opts, :ticks)
    tick_ms = Keyword.get(opts, :tick_ms, 5)
    scenario_opts = Keyword.get(opts, :scenario_opts, [])

    reset_app_state!()

    started_at = System.monotonic_time(:millisecond)

    summary =
      Engine.run(
        scenario: module,
        scenario_opts: scenario_opts,
        seed: seed,
        ticks: ticks,
        tick_interval_ms: tick_ms,
        validate: true,
        validate_every: 50
      )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    passed = summary.invariants.passed
    status = if passed, do: "OK", else: "FAIL"

    Mix.shell().info("  [#{status}] #{name} seed=#{seed} ticks=#{ticks} #{elapsed_ms}ms")

    %{
      scenario: name,
      seed: seed,
      ticks: ticks,
      elapsed_ms: elapsed_ms,
      passed: passed,
      violation_count: summary.invariants.violation_count,
      violations: summary.invariants.violations
    }
  end

  # --- Aggregate + summary ---

  defp build_aggregate(tier_results) do
    all_runs = Enum.flat_map(tier_results, & &1.runs)

    %{
      tiers: tier_results,
      total_runs: length(all_runs),
      passed_runs: Enum.count(all_runs, & &1.passed),
      failed_runs: Enum.reject(all_runs, & &1.passed),
      overall_passed: Enum.all?(tier_results, & &1.passed)
    }
  end

  defp emit_summary(aggregate) do
    Mix.shell().info("")
    Mix.shell().info("=== Sim.Hammer summary ===")
    Mix.shell().info("Total runs: #{aggregate.total_runs}")
    Mix.shell().info("Passed:     #{aggregate.passed_runs}")
    Mix.shell().info("Failed:     #{aggregate.total_runs - aggregate.passed_runs}")

    Enum.each(aggregate.tiers, fn tier ->
      status = if tier.passed, do: "OK", else: "FAIL"
      Mix.shell().info("  #{status} tier=#{tier.tier} runs=#{length(tier.runs)}")
    end)

    if aggregate.overall_passed do
      Mix.shell().info("=== Sim.Hammer: ALL TIERS PASSED ===")
    else
      Mix.shell().error("=== Sim.Hammer: FAILURES DETECTED ===")

      Enum.each(aggregate.failed_runs, fn r ->
        Mix.shell().error("  FAIL #{r.scenario} seed=#{r.seed} violations=#{r.violation_count}")
      end)
    end
  end

  # --- Boot ---

  # Full teardown + fresh boot between runs. Store ETS + WAL,
  # subaddress counters, reserves history all reset. Tolerates
  # being called before the first Application.start (initial run).
  defp reset_app_state! do
    case Application.stop(:perpwalk) do
      :ok -> :ok
      {:error, {:not_started, :perpwalk}} -> :ok
      {:error, other} -> raise "reset_app_state!: stop failed: #{inspect(other)}"
    end

    Boot.prepare!()
    {:ok, _} = Application.ensure_all_started(:perpwalk)
    :ok
  end
end
