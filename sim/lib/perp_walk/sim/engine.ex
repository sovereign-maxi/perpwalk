defmodule PerpWalk.Sim.Engine do
  @moduledoc """
  Orchestrates a simulation run.

  Lifecycle:

  1. `accelerate/0` on `Sim.Clock` so schedulers tick fast.
  2. Reset metrics + subaddress provider.
  3. Resolve the scenario module → actor mix + scenario state.
  4. Start actor processes (one per `count` per spec).
  5. Tick loop:
     - Send `:tick` to every actor
     - Yield briefly so actors can act
     - Drive the scenario's `on_tick/3` for any scripted events
     - Force-tick the production schedulers via `Sim.Clock`
     - Record tick metric
  6. On completion, stop actors, build report via `Sim.Reporter`.

  Synchronous-ish: ticks proceed at a fixed wall-clock interval
  (`:tick_interval_ms`, default 100ms). Actors process ticks
  asynchronously inside their own GenServer mailboxes — the
  engine doesn't wait for actor completion before the next tick.
  This is intentional: production traffic is asynchronous too.
  Determinism comes from per-actor RNG seeds, not synchronous
  ordering.
  """

  use GenServer

  require Logger

  alias PerpWalk.Sim.Clock
  alias PerpWalk.Sim.Invariants.Validator
  alias PerpWalk.Sim.Metrics
  alias PerpWalk.Sim.Reporter
  alias PerpWalk.Sim.Run
  alias PerpWalk.Sim.Subaddresses

  @default_tick_interval_ms 100
  @default_ticks 600

  @type config :: %{
          required(:scenario) => module(),
          required(:scenario_opts) => keyword(),
          required(:seed) => integer(),
          required(:ticks) => pos_integer(),
          required(:tick_interval_ms) => pos_integer(),
          optional(:validate) => boolean(),
          optional(:validate_every) => pos_integer(),
          optional(:proof_cycle_every) => pos_integer()
        }

  # --- Public API ---

  @doc """
  Runs a simulation to completion. Blocks until `:ticks` ticks
  have elapsed; returns the final report.

  ## Required opts

  - `:scenario` — module implementing `Sim.Scenarios.Scenario`
  - `:seed` — integer seed for RNG reproducibility

  ## Optional opts

  - `:scenario_opts` — keyword list passed to scenario init
  - `:ticks` — total tick count (default `#{@default_ticks}`)
  - `:tick_interval_ms` — wall-clock ms per tick (default `#{@default_tick_interval_ms}`)
  - `:validate` — run invariant validators (default false)
  """
  @spec run(keyword()) :: Reporter.summary()
  def run(opts) do
    config = build_config(opts)
    {:ok, pid} = GenServer.start_link(__MODULE__, config)

    try do
      GenServer.call(pid, :run, :infinity)
    after
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end
  end

  # --- GenServer ---

  @impl true
  def init(config) do
    # Trap exits so a dying actor doesn't cascade to the Engine +
    # sim main process. The Crash scenario deliberately kills
    # `:markets_store`; any actor with a call in flight receives
    # `exit(:killed)` and dies. Without trap_exit, the first such
    # death takes the sim down before the scenario can validate
    # the recovery invariant (Replay). Same protection applies to
    # any transient scheduler/GenServer restart during a run.
    Process.flag(:trap_exit, true)

    {:ok, %{config: config, actor_pids: [], scenario_state: nil, tick: 0, violations: []}}
  end

  @impl true
  def handle_call(:run, _from, state) do
    state
    |> prepare()
    |> tick_loop()
    |> finalise()
  end

  # Actor exits arrive as messages because we trap_exit above.
  # tick_loop is synchronous inside handle_call so these queue up
  # until the run ends; on the way out `finalise` stops any still-
  # alive actors cleanly. Handled here for the rare receive path
  # (e.g. if a scenario is ever reworked to send messages between
  # ticks). `:normal` is silent so the finalise-time normal stops
  # don't spam logs.
  @impl true
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.warning("Engine: actor exited, pid=#{inspect(pid)}, reason=#{inspect(reason)}")
    {:noreply, %{state | actor_pids: List.delete(state.actor_pids, pid)}}
  end

  # --- Run lifecycle ---

  defp prepare(state) do
    Clock.accelerate()
    Metrics.reset()
    Subaddresses.reset()
    reset_event_driven_invariants()
    Run.mark_started()

    {:ok, %{actors: actor_specs, state: scenario_state}} =
      apply(state.config.scenario, :init, [state.config.scenario_opts])

    actor_pids = start_actors(actor_specs, state.config.seed)

    Logger.info(
      "Engine: started, scenario=#{inspect(state.config.scenario)}, actors=#{length(actor_pids)}, ticks=#{state.config.ticks}"
    )

    %{state | actor_pids: actor_pids, scenario_state: scenario_state}
  end

  defp tick_loop(state) do
    Enum.reduce(1..state.config.ticks, state, fn tick, state ->
      {us, _} = :timer.tc(fn -> send_tick_to_all(state.actor_pids) end)
      Metrics.incr({:tick_phase, :send_tick, :us}, us)

      {us, _} = :timer.tc(fn -> Process.sleep(state.config.tick_interval_ms) end)
      Metrics.incr({:tick_phase, :sleep, :us}, us)

      {us, scenario_state} = :timer.tc(fn -> run_scenario_tick(state, tick) end)
      Metrics.incr({:tick_phase, :scenario, :us}, us)

      # Production schedulers (Markets.Scheduler, Federation.Signer)
      # auto-tick autonomously at the interval configured by
      # `Sim.Clock.accelerate/1`. The engine no longer drives them
      # synchronously — that previously caused queue-feedback under
      # `--validate` where the scheduler mailbox built up faster
      # than the slowed engine could drain it.

      # The reserves proof cycle is the one production scheduler the
      # sim cannot accelerate via Application config — `Vault.Generator`
      # is an upstream library and we don't reach into its internals.
      # Instead, drive it via its public `generate_now/0` API every N
      # ticks. Hits the same `run_proof_cycle` code path the timer
      # would, with no vault-side coupling. Set `proof_cycle_every: 0`
      # to opt out per scenario.
      maybe_trigger_proof_cycle(state.config.proof_cycle_every, tick)

      Metrics.incr({:tick, :count})

      {us, violations} =
        :timer.tc(fn ->
          if state.config.validate and rem(tick, state.config.validate_every) == 0,
            do: Validator.validate() ++ state.violations,
            else: state.violations
        end)

      Metrics.incr({:tick_phase, :validate, :us}, us)

      %{state | tick: tick, scenario_state: scenario_state, violations: violations}
    end)
  end

  defp finalise(state) do
    Logger.info("Engine: stopping actors, count=#{length(state.actor_pids)}")
    Enum.each(state.actor_pids, &stop_actor/1)

    Clock.restore()
    Run.mark_finished()

    summary =
      Reporter.build(
        [
          scenario: inspect(state.config.scenario),
          seed: state.config.seed,
          ticks: state.config.ticks,
          tick_interval_ms: state.config.tick_interval_ms,
          validate: state.config.validate
        ],
        Enum.reverse(state.violations)
      )

    Logger.info("Engine: complete, ticks=#{state.tick}")
    {:reply, summary, state}
  end

  # --- Actor lifecycle ---

  defp start_actors(specs, run_seed) do
    specs
    |> Enum.with_index()
    |> Enum.flat_map(fn {spec, spec_idx} ->
      module = role_to_module(spec.role)

      for actor_idx <- 1..spec.count do
        seed = run_seed * 1_000_000 + spec_idx * 1_000 + actor_idx
        opts = (Map.get(spec, :opts) || []) ++ [seed: seed]
        {:ok, pid} = apply(module, :start_link, [opts])
        pid
      end
    end)
  end

  defp role_to_module(:creator), do: PerpWalk.Sim.Actors.Creator
  defp role_to_module(:voter), do: PerpWalk.Sim.Actors.Voter
  defp role_to_module(:trader), do: PerpWalk.Sim.Actors.Trader
  defp role_to_module(:disputer), do: PerpWalk.Sim.Actors.Disputer
  defp role_to_module(:guardian), do: PerpWalk.Sim.Actors.Guardian
  defp role_to_module(:claimer), do: PerpWalk.Sim.Actors.Claimer
  defp role_to_module(:adversary), do: PerpWalk.Sim.Actors.Adversary
  defp role_to_module(:underpayer), do: PerpWalk.Sim.Actors.Underpayer

  defp send_tick_to_all(pids), do: Enum.each(pids, &send(&1, :tick))

  # Two-phase actor shutdown. Actors can accumulate large `:tick`
  # mailbox queues under load — the `GenServer.stop/3` politeness call
  # waits behind that entire queue and times out. `catch :exit, _`
  # swallows the timeout, so without a force-kill the actor keeps
  # running: it drains its queued ticks (each calling into services
  # like `Sim.Subaddresses`), and during the between-scenario window
  # where `Application.stop` has torn down the sim provider but
  # `Application.ensure_all_started` hasn't rebuilt it yet, the actor's
  # call returns `{:error, :provider_not_started}` and crashes with a
  # MatchError. Force-kill after the graceful attempt guarantees no
  # actor survives past finalise/1.
  defp stop_actor(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end

      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end

    :ok
  end

  # --- Scenario integration ---

  defp run_scenario_tick(state, tick) do
    case apply(state.config.scenario, :on_tick, [DateTime.utc_now(), tick, state.scenario_state]) do
      {:ok, events, scenario_state} ->
        Enum.each(events, &dispatch_event/1)
        scenario_state

      _ ->
        state.scenario_state
    end
  end

  defp dispatch_event(:halt) do
    if Code.ensure_loaded?(PerpWalk.Federation.Signer) do
      PerpWalk.Federation.Signer.halt()
    end
  end

  defp dispatch_event(:resume) do
    if Code.ensure_loaded?(PerpWalk.Federation.Signer) do
      PerpWalk.Federation.Signer.resume()
    end
  end

  defp dispatch_event({:override_resolution, market_id, outcome}) do
    _ = PerpWalk.Markets.Facade.override_resolution(market_id, outcome)
  end

  defp dispatch_event(other) do
    Logger.debug("Engine: unhandled scenario event, event=#{inspect(other)}")
  end

  # --- Config ---

  # Event-driven invariants accumulate violations in their own
  # GenServer state across the run. A fresh sim run needs each one
  # cleared so violations from the prior run don't leak in.
  defp reset_event_driven_invariants do
    for mod <- [
          PerpWalk.Sim.Invariants.Lifecycle,
          PerpWalk.Sim.Invariants.Idempotency,
          PerpWalk.Sim.Invariants.Ownership,
          PerpWalk.Sim.Invariants.Uniqueness,
          PerpWalk.Sim.Invariants.Conservation,
          PerpWalk.Sim.Invariants.Payout.Pipeline,
          PerpWalk.Sim.Invariants.Orphans,
          PerpWalk.Sim.Invariants.Creator.Economics
        ],
        Code.ensure_loaded?(mod),
        function_exported?(mod, :reset, 0) do
      mod.reset()
    end

    :ok
  end

  defp maybe_trigger_proof_cycle(0, _tick), do: :ok

  defp maybe_trigger_proof_cycle(every, tick) when rem(tick, every) == 0 do
    if Code.ensure_loaded?(Vault.Generator) and
         function_exported?(Vault.Generator, :generate_now, 0) do
      try do
        Vault.Generator.generate_now()
        Metrics.incr({:reserves, :proof_cycle_requested})
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp maybe_trigger_proof_cycle(_every, _tick), do: :ok

  defp build_config(opts) do
    %{
      scenario: Keyword.fetch!(opts, :scenario),
      scenario_opts: Keyword.get(opts, :scenario_opts, []),
      seed: Keyword.fetch!(opts, :seed),
      ticks: Keyword.get(opts, :ticks, @default_ticks),
      tick_interval_ms: Keyword.get(opts, :tick_interval_ms, @default_tick_interval_ms),
      validate: Keyword.get(opts, :validate, false),
      validate_every: max(1, Keyword.get(opts, :validate_every, 1)),
      proof_cycle_every: max(0, Keyword.get(opts, :proof_cycle_every, 10))
    }
  end
end
