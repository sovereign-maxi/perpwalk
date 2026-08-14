# PERP WALK — Simulation Harness

In-process actor simulation against the live PERP WALK BEAM. Drives the markets, federation, and reserves stack the same way real users do — through the public Facades — and asserts invariants over the resulting state.

## Why a sim

PERP WALK has too many concurrent actors (creators, voters, traders, disputers, guardians, claimers, scheduler ticks, federation signers, reserves cycles) for traditional unit-or-integration coverage to catch interaction bugs. The sim composes hundreds of these actors against the same supervision tree the production binary boots, drives them through scripted scenarios, and runs invariant validators over the resulting state.

## Quick start

Two entry points:

```
mix sim.events --scenario baseline --ticks 600 --seed 42 --validate
```

Reads back as: "wire up the baseline actor mix, run 600 ticks with the deterministic RNG seed 42, and run every invariant validator each tick. Report at the end." Good for iterating on a single scenario.

```
mix sim.hammer
```

Runs the full 5-tier progression: smoke → per-scenario → load 5x → soak → seed sweep. Each tier gates the next; the first failure aborts and surfaces the earliest reproducer. Good for pre-launch confidence + regression checks.

    mix sim.hammer --tier smoke         # single tier
    mix sim.hammer --skip-soak          # trim the long tail
    mix sim.hammer --skip-seed-sweep    # ditto
    mix sim.hammer --report path.json   # write JSON aggregate

## Layout

```
sim/
├── lib/
│   ├── mix/tasks/
│   │   ├── sim.events.ex        # `mix sim.events` — single scenario driver
│   │   └── sim.hammer.ex        # `mix sim.hammer` — 5-tier progression
│   └── perp_walk/sim/
│       ├── boot.ex              # pre-`app.start` prep (wipe data, suppress endpoints, install overrides)
│       ├── engine.ex            # tick loop, actor lifecycle, scenario dispatch
│       ├── supervisor.ex        # sim child tree (Subaddresses, Metrics, event-driven invariants)
│       ├── clock.ex             # accelerates production schedulers
│       ├── run.ex               # persistent_term run-context (entity filter window)
│       ├── reporter.ex          # post-run JSON summary
│       ├── metrics.ex           # tick + event counters
│       ├── subaddresses.ex      # in-mem subaddress provider (replaces Monero RPC)
│       ├── crash.ex             # crash-injector helpers for the `crash` scenario
│       ├── signing/             # `Backend` — sim-mode payout signing backend
│       ├── reserves/            # `Source` — bookkeeping-derived reserves for the sim
│       ├── actors/              # one module per role; each is a tick-driven GenServer
│       ├── scenarios/           # actor mix + scripted on_tick/3 timeline
│       └── invariants/          # Validator + per-invariant Conservation/Lifecycle/...
└── test/
    └── unit/perp_walk/sim/      # unit tests for the harness itself
```

`mix.exs` adds `sim/lib` to `:dev` and `:test` `elixirc_paths` and `sim/test` to `:test` `test_paths`. The production release explicitly excludes `sim/lib` so no sim code can ship.

## Components

### Boot (`Sim.Boot`)

Both mix tasks call `Boot.prepare!/0` BEFORE `Mix.Task.run("app.start")`. This is load-bearing — see the moduledoc in `boot.ex` for why. In order:

1. `wipe_data_dir!/0` — nukes the app's data directory so prior-run WAL entries, DETS orphans, and reserves proofs don't bleed into the fresh run. Uses `Application.get_env(:perpwalk, :data_dir)` (the same path the running app resolves), NOT the `PERPWALK_DATA_DIR` env var directly — earlier versions did the latter and silently no-op'd on production hardware where the env var pointed outside cwd.
2. `suppress_web_endpoints!/0` — sets `server: false`, empty watchers, disabled code_reloader + live_reload on BOTH `PerpWalkWeb.Endpoint` and `PerpWalkAdminWeb.Endpoint`. Missing either endpoint means it boots a real HTTP server on every run, dirties working-tree assets via esbuild, and leaves TIME_WAIT ports.
3. `install_overrides!/0` — swaps `PerpWalk.Sim.Reserves.Source` in for the wallet-RPC reserves source, and `PerpWalk.Sim.Signing.Backend` in for the federation signing backend. Both live under `sim/lib` so `:prod` releases never see them.

`mix sim.hammer`'s `reset_app_state!/0` calls `Boot.prepare!/0` between every scenario run to guarantee a truly fresh boot per scenario.

### Engine (`Sim.Engine`)

Owns the tick loop. Each tick: send `:tick` to every actor process, yield briefly so they act, drive the scenario's `on_tick/3` for any scripted events, record the tick metric. Default 600 ticks @ 100ms = 60s wall-clock per run.

Synchronous-ish, not strictly synchronous — actors process ticks asynchronously inside their own GenServer mailboxes. Production traffic is asynchronous too. Determinism comes from per-actor RNG seeds, not synchronous ordering.

Actor shutdown is two-phase (see `stop_actor/1`): graceful `GenServer.stop(:normal, 1_000)` first, then `Process.exit(:kill)` if still alive. Actors with large `:tick` mailbox backlogs can't drain in 1 second, and `:normal` engine exits don't cascade to linked processes — without the force-kill, actors leak across scenario boundaries and eventually call into services like `Sim.Subaddresses` during a between-scenario window, crashing with `:provider_not_started`.

### Supervisor (`Sim.Supervisor`)

Started as an `extra_children` entry so it runs inside the perpwalk application supervision tree. Children:

- `Sim.Subaddresses` — subaddress allocator (see below)
- `Sim.Metrics` — flat counter/timer collector
- Event-driven invariants — `Lifecycle`, `Idempotency`, `Ownership`, `Uniqueness`, `Conservation`, `Payout.Pipeline`, `Orphans`, `Creator.Economics`. Each subscribes to relevant `PerpWalk.Events.*` topics on init; supervisor placement guarantees Phoenix.PubSub is already up.

Between runs, `reset_event_driven_invariants/0` in the engine calls each invariant's `reset/0` so accumulator state doesn't leak into the next scenario.

### Actors (`Sim.Actors.*`)

Each actor is a tick-driven GenServer that probabilistically takes its role's actions against the public Facades:

| Actor        | Role |
|--------------|------|
| `Creator`    | Mints markets via `Markets.Facade.create_market/1` |
| `Voter`      | Casts up/down votes via `Markets.Facade.cast_vote/3` |
| `Trader`     | Creates Quotes and fills positions via `Markets.Facade.create_quote/4` + `fill_quote/1` |
| `Disputer`   | Files disputes via `Markets.Facade.start_dispute/2` |
| `Guardian`   | Acknowledges or reverses resolutions via `Markets.Facade.acknowledge_disputes/1` and `reverse_resolution/2` |
| `Claimer`    | Claims position payouts, dispute refunds, and creator LP returns via `Markets.Facade.claim_payout/3`, `claim_dispute_refund/3`, and `claim_creator_lp_return/3` |
| `Adversary`  | Malicious-creator behavior for the `adversarial` scenario |
| `Underpayer` | Deliberately-underpaid deposits — exercises the orphan/refund pipeline for scenarios that need it |

All actors implement `Sim.Actors.Behaviour` (`init/1` + `handle_tick/2`).

Behaviours like `:dispute_p`, `:malice_p`, `:up_bias` configure each role. RNG is seeded per-actor from the run seed so any failure can be reproduced bit-for-bit by re-running with the same `--seed`.

### Scenarios (`Sim.Scenarios.*`)

A scenario declares the actor mix and a per-tick `on_tick/3` callback for scripted events (timed crashes, halt commands, etc).

| Scenario              | Purpose |
|-----------------------|---------|
| `Baseline`            | Honest actors, full lifecycle. Smoke test |
| `Dishonesty`          | Creators write ambiguous criteria and resolve dishonestly; expect dispute-driven reversals |
| `Spam`                | Sybil disputers flag every resolution |
| `Listings`            | Flood of low-quality market proposals |
| `Deadlines`           | Many simultaneous expirations |
| `Halt`                | Operator halts mid-flow |
| `Race`                | Settle vs dispute concurrent race |
| `Crash`               | Random process crashes mid-run via `Sim.Crash` |
| `Adversarial`         | Adversary creators trying to extract via dishonest resolution |
| `Underpayment`        | Underpayer flow — validates the orphan-deposit pipeline and refund path |
| `Federation.Income`   | Operator federation-income withdrawal flow under contention |
| `Processor.Failover`  | Designated-processor promotion/failover mid-flow |

Add a scenario by implementing `PerpWalk.Sim.Scenarios.Scenario` (`init/1` and `on_tick/3`). New scenarios are picked up by `mix sim.events --scenario <name>` automatically once the short-name maps in `Mix.Tasks.Sim.Events.scenario_module/1`.

### Invariants (`Sim.Invariants.*`)

Run when `--validate` is passed (each tick) or after the run via `Sim.Invariants.Validator.validate/0` from iex.

| Invariant             | What it checks |
|-----------------------|----------------|
| `Conservation`        | Federation-revenue ledger sums match independently re-derived totals from disputes + rejected markets |
| `Lifecycle`           | No illegal market or dispute state transitions |
| `Ownership`           | Positions stay attached to the market they were opened on |
| `Uniqueness`          | At most one vote and one dispute per `(account, market)` |
| `Idempotency`         | Re-running a command with the same id is a no-op |
| `Replay`              | Replaying the WAL produces identical ETS state |
| `Concurrency`         | No double-payout or double-refund under concurrent claims |
| `Halt`                | Auto-signing actually pauses when `Federation.Signer.halt/0` is called |
| `Reserves`            | Every reserves proof satisfies `total_held >= outstanding`, carries at least one attestation, and (when published) has a non-nil threshold signature |
| `Payout.Pipeline`     | Every enqueued payout progresses through the expected lifecycle states without stalling or double-transitioning |
| `Orphans`             | Orphaned deposits accumulate in `Monero.Orphans` and can be resolved without leaking state across runs |
| `Creator.Economics`   | Creator LP deposits are returned as expected on settle/void; residual accrues to the creator, not the venue |
| `Replication`         | Stub. Single-node sim has no follower in its supervision tree, so this is a no-op that returns `:ok`. Multi-node mode (deferred) is where leader-follower convergence assertion lands. |

Each invariant returns `:ok` or `{:violation, %{kind: ..., ...}}`. The `Validator` aggregates violations per tick and the run reporter surfaces them in the summary.

### Subaddresses (`Sim.Subaddresses`)

Replaces the live `Monero.Facade.create_subaddress/0` with an in-memory counter-based provider so the sim doesn't need a running `monero-wallet-rpc`. Configured via `:perpwalk, :monero_subaddress_provider` in `config/test.exs` and `config/dev.exs`.

### Clock (`Sim.Clock`)

Compresses the production schedulers' wall-clock cadence to sim time:

- `Markets.Scheduler`, `Federation.Signer`, `Storage.Replicator`, `Storage.Checkpointer` auto-tick at `@default_scheduler_tick_ms` (100 ms).
- `Vault.Generator` proof cycle fires at `@default_reserves_interval_ms` (500 ms) instead of the production 10-minute cadence. Uses `Vault.Generator.set_interval/1` to reach the already-running process.
- `Federation.peer_nodes_override` is set to `[Node.self()]` so the reserves attestation collector's RPC roundtrip executes locally (real HMAC sign + verify, real Ed25519 attestation, real signature verification) without needing a second BEAM node. Multi-peer divergence remains out of scope for single-node sim and waits on the deferred multi-node sim mode.

Without these accelerations a 60-second sim would see zero reserves proofs and only a handful of scheduler-driven transitions.

### Run (`Sim.Run`)

Records the run's start timestamp in `:persistent_term` so invariant modules can filter their checks to entities created during the current run, ignoring leftover WAL state from prior dev or test sessions. No GenServer roundtrips on the read path.

### Reporter (`Sim.Reporter`)

Post-run summary. Pulls `Sim.Metrics.snapshot/0`, the markets + federation + reserves state via the public Facades, the federation-revenue ledger via `Markets.Facade.federation_ledger/0`, and any invariant violations recorded by the validator. Emits as a structured map; the mix task `Jason.encode!`s it for stdout or `--report PATH`.

## Determinism

Re-running with the same `--seed` produces the same actor decisions, the same scheduler-tick ordering, and (modulo BEAM scheduler nondeterminism inside actor mailboxes) the same final state. When chasing a failure, capture the seed from the run summary and re-run.

## Adding a new role

1. Create `sim/lib/perp_walk/sim/actors/<role>.ex` implementing `Sim.Actors.Behaviour` (`init/1`, `handle_tick/2`).
2. Wire it up in the relevant scenarios' `actors` list.
3. (Optional) Add a CLI override so `mix sim.events --<role> N` adjusts the count.

## Adding a new invariant

1. Create `sim/lib/perp_walk/sim/invariants/<name>.ex` exporting `check/1` over the snapshot map (`%{markets, positions, disputes, payouts, federation_ledger}`).
2. Add the module to `Sim.Invariants.Validator.@invariants`.
3. Add a unit test under `sim/test/unit/perp_walk/sim/invariants/`.

## Limits

- Actors call the same Facades production callers do — there is no parallel "test-only" code path. A bug the sim catches is a bug production would hit.
- The sim does **not** exercise the real `monero-wallet-rpc` or any federated multisig signing. Those are stubbed via the in-mem subaddress provider and the test signer backend. End-to-end Monero coverage is a separate concern; the sim covers the orchestration above the wallet boundary.
- The sim shares the BEAM with the production stack — it cannot run alongside a live node. Use a dedicated dev or CI environment.
- **Destructive:** `Boot.wipe_data_dir!/0` deletes the app's entire data directory on every run. Never point `PERPWALK_DATA_DIR` at anything you don't want blown away. The safety check refuses `nil`, `""`, `/`, `.` but otherwise trusts the configured path.
