defmodule PerpWalk.Sim.Clock do
  @moduledoc """
  Time-acceleration helpers for sim runs.

  PERP WALK doesn't use a swappable clock abstraction — modules
  call `DateTime.utc_now/0` directly. To compress "30 days of
  operation" into "5 minutes of wall time" the sim:

  1. Sets the supervised perpwalk schedulers (`Markets.Scheduler`,
     `Federation.Signer`, `Storage.Replicator`, `Storage.Checkpointer`)
     to auto-tick at a sim-appropriate interval (`@default_scheduler_tick_ms`).
  2. Routes the reserves attestation collector to `Node.self()` via
     the `:peer_nodes_override` test seam so the Collector → Peer
     RPC roundtrip runs locally (real HMAC, real Ed25519, real
     signature verify) without needing a second BEAM node.
  3. Builds market durations from `compress/1` so a market's
     lifecycle (listing window → expiry → resolution deadline →
     dispute window → settle) lands inside seconds, not days.

  The reserves proof cycle is intentionally NOT compressed here —
  `Vault.Generator` is an upstream library and we don't reach into
  its internals from the sim. Scenarios that want proof coverage
  call `Vault.Generator.generate_now/0` from their `on_tick/3`
  callback every N ticks; that hits the same `run_proof_cycle`
  code path the timer would, with no vault-side coupling.

  `force_tick_schedulers/0` is kept as a public utility for
  interactive debugging and tests that need a synchronous "settle
  state now" handle, but the Engine no longer calls it on every
  tick — schedulers run autonomously and the engine just lets them
  catch up between its own ticks.

  Stateless module — all state lives in `Application` config.
  Sim runs that wrap a scenario in `accelerate/0` ... actor work
  ... `restore/0` cleanly leave the env they found.

  ## Compression ratio

  Default compression maps 1 simulated day → 1 wall-clock second.
  A 30-day sim run is ~30 seconds of action plus actor tick
  overhead. Override via `accelerate/1` opts.
  """

  require Logger

  alias PerpWalk.Federation.Signer, as: FederationSigner
  alias PerpWalk.Markets.Scheduler, as: MarketsScheduler

  # Schedulers auto-tick autonomously in sim mode at this interval.
  # The Engine no longer force-ticks them — letting BOTH drive the
  # scheduler queue caused a feedback loop where validator-slow
  # engine ticks let the scheduler's auto-tick mailbox accumulate,
  # and every synchronous run_now from the engine then had to wait
  # behind that backlog. With auto-tick alone there is one driver
  # and no queue contention; the scheduler stays close to real-time
  # because its work-per-tick is small.
  #
  # 100 ms is fast enough to catch compressed lifecycle transitions
  # (default compression: 1 virtual day = 1 wallclock second, so
  # 100 ms is ~2.4 virtual hours per scheduler tick) and slow enough
  # that the scheduler's own work doesn't dominate the BEAM.
  @default_scheduler_tick_ms 100
  @default_compression 86_400

  # --- Public API ---

  @doc """
  Configures all background schedulers for fast auto-ticking.

  Idempotent — safe to call multiple times. Stores prior values
  under `:perpwalk, :sim_clock_saved` so `restore/0` can put them
  back.

  Schedulers run autonomously in sim mode. The Engine no longer
  drives them synchronously — see the `@default_scheduler_tick_ms`
  module attribute for the rationale.
  """
  @spec accelerate(keyword()) :: :ok
  def accelerate(opts \\ []) do
    interval = Keyword.get(opts, :scheduler_tick_ms, @default_scheduler_tick_ms)

    saved = %{
      markets_scheduler: Application.get_env(:perpwalk, :markets_scheduler, []),
      federation_signer: Application.get_env(:perpwalk, :federation_signer, []),
      storage_replicator: Application.get_env(:perpwalk, :storage_replicator, []),
      storage_checkpointer: Application.get_env(:perpwalk, :storage_checkpointer, []),
      federation: Application.get_env(:perpwalk, :federation, [])
    }

    Application.put_env(:perpwalk, :sim_clock_saved, saved)

    Application.put_env(:perpwalk, :markets_scheduler,
      tick_interval_ms: interval,
      pending_window_seconds: 1,
      auto_void_grace_seconds: 1
    )

    Application.put_env(:perpwalk, :federation_signer,
      tick_interval_ms: interval,
      signing_backend: Keyword.get(saved.federation_signer, :signing_backend, :stub)
    )

    Application.put_env(:perpwalk, :storage_replicator, tick_interval_ms: interval)
    Application.put_env(:perpwalk, :storage_checkpointer, interval_ms: interval)

    # Route the reserves attestation collector to `Node.self()` so the
    # full Collector → Peer.attest_snapshot → HMAC verify → Ed25519
    # sign → response verify path runs in single-node sim mode. The
    # collector reads this config each `collect/1`, so the override
    # takes effect immediately without restarting any supervisors.
    # Multi-peer divergence is out of scope for single-node sim and
    # waits on the deferred multi-node sim mode.
    Application.put_env(
      :perpwalk,
      :federation,
      Keyword.put(saved.federation, :peer_nodes_override, [Node.self()])
    )

    # The schedulers cache their config at init, so put_env above
    # has no effect on already-running processes. Push the new
    # values directly into the live scheduler state.
    if Code.ensure_loaded?(MarketsScheduler) and
         function_exported?(MarketsScheduler, :reconfigure, 1) do
      try do
        MarketsScheduler.reconfigure(
          tick_interval_ms: interval,
          pending_window_seconds: 1,
          auto_void_grace_seconds: 1
        )
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @doc """
  Restores the scheduler configuration that was active before the
  most recent `accelerate/1`. No-op if `accelerate/1` was never
  called.
  """
  @spec restore() :: :ok
  def restore do
    case Application.get_env(:perpwalk, :sim_clock_saved) do
      nil ->
        :ok

      saved when is_map(saved) ->
        Application.put_env(:perpwalk, :markets_scheduler, saved.markets_scheduler)
        Application.put_env(:perpwalk, :federation_signer, saved.federation_signer)
        Application.put_env(:perpwalk, :storage_replicator, saved.storage_replicator)
        Application.put_env(:perpwalk, :storage_checkpointer, saved.storage_checkpointer)
        Application.put_env(:perpwalk, :federation, Map.get(saved, :federation, []))
        Application.delete_env(:perpwalk, :sim_clock_saved)
        :ok
    end
  end

  @doc """
  Drives all schedulers to flush pending work. Called by the
  engine between actor rounds so time-based transitions land
  before invariants run.

  Crash-safe: each scheduler's `run_now/0` is wrapped — if a
  scheduler isn't started (test/dev variant) the call is skipped
  rather than crashing the engine.
  """
  @spec force_tick_schedulers() :: :ok
  def force_tick_schedulers do
    safe_run_now(MarketsScheduler)
    safe_run_now(FederationSigner)
    :ok
  end

  @doc """
  Compresses a real-world duration (in seconds) into a sim
  duration. The default ratio maps 1 day of real time → 1 second
  of sim time, so a 7-day market expiry becomes 7 seconds.

  Returns at least 1 — sub-second windows are rounded up to keep
  the durations valid.
  """
  @spec compress(non_neg_integer(), pos_integer()) :: pos_integer()
  def compress(real_seconds, ratio \\ @default_compression)
      when is_integer(real_seconds) and real_seconds >= 0 and is_integer(ratio) and ratio > 0 do
    max(1, div(real_seconds, ratio))
  end

  # --- Internal ---

  defp safe_run_now(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :run_now, 0) do
      try do
        module.run_now()
      catch
        :exit, _ -> :ok
        kind, reason ->
          Logger.warning("Clock: #{inspect(module)} run_now failed, kind=#{kind}, reason=#{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end
end
