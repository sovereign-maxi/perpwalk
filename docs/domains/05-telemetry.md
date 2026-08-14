# PERP WALK — Telemetry Domain

Operator visibility. Alerts, metrics, health scoring, and Nostr DMs.

---

## Purpose

Telemetry is how PERP WALK tells its operator what's happening, what's wrong, and when to intervene. It runs alert rules over the live system, maintains a 4-state health model, exposes health endpoints for liveness probes, surfaces a real-time event stream on the admin dashboard, and pushes critical events to the operator's Nostr DM.

The domain is read-only with respect to other domains — it observes via facades and the EventBus. It never reaches into another domain's internals.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Alert rule** | A named check that periodically evaluates a condition and emits an alert if true |
| **Severity** | `info` / `warning` / `critical` / `emergency` — drives publication channels and health impact |
| **Health state** | `healthy` / `degraded` / `critical` / `halted` — system-wide aggregate |
| **Halt** | Auto-imposed read-only mode triggered by emergency alerts or manual operator action |
| **Pip** | A status indicator on the user-facing footer (e.g. Tor / Lightning / XMR — green, amber, red) |
| **Event stream** | Live LiveView feed on admin dashboard of recent domain events |
| **Nostr DM** | NIP-17 gift-wrapped message to the operator's pubkey via configured relays |
| **Snapshot** | Point-in-time view of system metrics for the dashboard |

## Aggregates

**Alerts.Manager** (singleton GenServer)
- Owns the alert rule registry
- Schedules periodic evaluation per rule
- Routes alert publication to dashboard event stream and EventBus

**Alerts.Rule** — value object
- name, severity, period, condition fn, detail formatter

**Health.Cache** (ETS)
- Latest values from each domain (market counts, resolution backlog, WAL stats, replication tick) for fast rule evaluation
- Updated by event handlers and periodic polls, not polled by alerts directly
- Subscribes to `FederationEvents.BootstrapAddressMismatch` for the sticky bootstrap-mismatch banner. Quorum and signing-halt status flow through the `:federation_quorum_lost` alert rule and `Health.System`'s halt model, not via direct Cache subscription.
- Consumes `[:perp_walk, :storage, :replicator, :tick]` telemetry from `Storage.Replicator` and stores `{cursor, peer_tip, lag, batch_size, result}` per peer under `:replicator_tick`. Rules `:peer_replication_lagging` (warn) and `:peer_replication_lagging_critical` (critical) fire from this surface. Every node runs a Replicator that tails every peer, so the rules apply uniformly across the cluster.

**Health.System** — health-state aggregator GenServer
- Aggregates alert states into the 4-state model (`:healthy | :degraded | :critical | :halted`)
- Halt state lives in two `:persistent_term` keys (`{Health.System, :manual_halt}` and `{Health.System, :auto_halt}`) so domains can check `halted?/0` without a GenServer round-trip. `set_halted/1` flips the manual key (and clears auto on `clear_halt/0`); the eval tick recomputes auto from the active halt-class alert set every cycle, so auto-halt self-clears once the underlying condition resolves.
- Halt classes (the alerts whose firing flips auto-halt to true): `:federation_quorum_lost`, `:disk_usage_critical_root`, `:disk_usage_critical_data`, `:data_volume_unmounted`. Any other alert raises health-state severity without halting.
- Every transition through `set_halted/1` and `clear_halt/0` writes a `Federation.Facade.record_audit/2` entry for forensic review.

**Health.Metrics** — gauge / counter store backing the admin metrics surface

**Metrics.Ring** — bounded ring-buffer of recent telemetry samples for the dashboard time-series widgets

## Commands

| Command | Description |
|---------|-------------|
| Evaluate rule | Run condition fn, emit alert on match, update Cache |
| Publish alert | Append to dashboard event stream, send Nostr DM if severity warrants |
| Halt system | Mark halted, reject new operations, alert operator |
| Resume system | Operator-issued (requires admin dashboard action) |
| Refresh dashboard | Periodic snapshot for LiveView render |

## Boundaries

**Owns**: Alert rules, severity classification, health state, halt mechanism, event stream ring buffer, metrics store, Nostr DM publication

**Depends on**:
- All domain facades (read-only) for data points
- EventBus for live event consumption
- `Storage.Facade` only to read counters / metrics

**Depended on by**:
- Operator console paths via `Telemetry.Facade.set_halted/1` (failsafe halt) and `clear_halt/0`
- Every write-path entry point via `PerpWalk.Guards.ensure_operational!/0`, which reads `Telemetry.Facade.halted?/0` and raises `PerpWalk.Guards.SystemHaltedError` when halted

## Published Language (Telemetry.Facade)

External callers interact with Telemetry exclusively through `PerpWalk.Telemetry.Facade`:

- **Health**: `system_status/0` (`:healthy | :degraded | :critical | :halted`), `health_components/0`, `halted?/0`, `halt_reason/0`, `health_cache_get/1` (diagnostic lookup keyed by e.g. `{:replicator_tick, origin}`)
- **Alerts**: `active_alerts/0`, `recent_resolved_alerts/2`
- **Metrics**: `system_metrics/0`, `metrics_series/2` (ring-buffer time series for the dashboard)
- **Halt control**: `set_halted/1`, `clear_halt/0`

No other Telemetry module is imported by any other domain.

## Events

**Publishes**:
- `SystemStatusChanged` — system moved between health states (carries old/new state)
- `AlertFired` — a rule evaluated truthy
- `AlertResolved` — a previously firing rule is now clean
- `TorDown` / `TorDegraded` / `TorRecovered` — outbound-tunnel reachability transitions

**Consumes**: All domain events (read-only) — used to update Health.Cache and the dashboard event stream

## Invariants

- An alert rule MUST evaluate without raising — all errors caught and the rule marked `:errored`
- Halt MUST be respected by every write-path entry via `PerpWalk.Guards.ensure_operational!/0`, which reads `Telemetry.Facade.halted?/0` and raises `PerpWalk.Guards.SystemHaltedError` when the system is halted
- Nostr publications MUST use ephemeral keys (per-message gift-wrap key) — operator's primary key is not exposed
- Metrics counters MUST be monotonic (never decremented)
- The event stream ring buffer MUST drop oldest entries when full (no unbounded memory growth)
- Critical alerts MUST be delivered to the operator's Nostr DM within one rule cycle

---
