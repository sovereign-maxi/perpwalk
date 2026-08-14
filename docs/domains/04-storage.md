# PERP WALK — Storage Domain

Durable state, crash recovery, and backup. WAL-first, ETS for hot reads, DETS for cold persistent records.

---

## Purpose

Storage is PERP WALK's durability layer. Every change of consequence — a market created, a position taken, a vote cast, a balance credited, a market settled — is written to the WAL before any in-memory or external effect. On crash, the WAL is replayed to rebuild ETS state.

PERP WALK uses no traditional database. The state is the WAL plus the ETS rebuild plus the DETS-backed cold tiers (orphan deposits, reserves proof history). Backup and restore of the on-disk state are operational concerns handled by external scripts; the application is responsible only for keeping that state consistent and durable on disk.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **WAL** | Write-Ahead Log — append-only sequence of domain events that durably record every state change |
| **Entry** | A single typed record in the WAL (market_created, position_opened, settlement_committed, etc.) |
| **Seq** | Monotonic 64-bit counter, allocated centrally via `Storage.WAL.Sealer.seal/1` before append. Followers validate seq monotonicity over each replicated batch before any local WAL write |
| **Replay** | Reading the WAL on startup to reconstruct in-memory state |
| **Snapshot** | A point-in-time export of state, used for fast restart and backup |
| **DETS** | Disk-backed term storage used for orphan deposit records and reserves proof history |
| **ETS** | In-memory term storage for hot reads (markets, positions, votes, quotes, disputes, payouts, sessions) |
| **Holder** | Reserved process for protected ETS tables that must outlive their writer. Currently owns no tables — domain Stores own their own ETS tables directly. Kept in the supervision tree for future use. |

## Aggregates

**WAL** (singleton)
- Append-only log file with rotation
- Cross-domain writes go through `Storage.Facade.seal_and_append/2,3`, which delegates to the centralised `Storage.WAL.Sealer`. The Sealer is the sole allocator of monotonic seq values — every cross-domain entry MUST pass through it. The seqless `write_wal/2` path was retired because seqless entries silently broke replication (replicating peers validate seq monotonicity over each batch before applying), and is no longer the cross-domain entry point.
- Fsync on every append before returning to caller — durability is unconditional

**Sealer** (singleton, `Storage.WAL.Sealer`)
- Wraps `Locker.WAL.append/2` with a single point of seq allocation. Both `seal_and_append/2,3` and the lower-level `seal/1` (just allocate, don't append) flow through here.
- Exists specifically so that cross-domain writes can't bypass the seq invariant — an entry written with `Locker.WAL.append/2` directly would have a seq from wherever the caller computed it, which is exactly the class of bug that broke replication before the Sealer was introduced.

**Holder** (singleton)
- Reserved process for protected ETS tables that must outlive their writer GenServer. Currently `@tables` is empty — every domain Store owns its own ETS tables directly. Kept in the supervision tree for future use (heir-transfer pattern when a domain needs cross-restart table persistence).

**Stores** (per-domain GenServers)
- `Markets.Store` (markets, positions, votes, quotes, disputes + secondary indexes + ledger counters) and `Federation.Store` (payouts + inflight / by-status / by-position indexes). Each owns its own ETS tables, serialises writes through the shared WAL, and replays its own subset of WAL types on boot via `apply_entries/2`.
- `Identity.Sessions` owns its own `:public` ETS table for the session_id → account_id map plus a `:private` ETS for in-memory-only seckey rows. Account-binding entries (`:session_created`, `:session_revoked`) are WAL-persisted and replayed on boot; the seckey rows are not.
- Identity persists no derived account state — the `account_id` is recomputed from the keyphrase on every request.
- Telemetry's metrics/alerts state is in-memory only (intentional — restarts wipe the chart, that's fine).

**Recovery / Runner** — boot orchestration
- `Storage.Runner` calls `Storage.Recovery.run/0` on boot, which currently reads the WAL through `Locker.WAL.read_all/1` and logs the entry count. The actual ETS rebuild happens inside each domain Store's `init/1` via `replay_wal/2 → apply_entries/2`.
- Recovery halts startup via `System.halt(1)` on `{:error, _}` from the WAL read; each Store also raises from `replay_wal/2` on `{:error, _}` so a substantive read failure can't boot the node to empty state and corrupt seq monotonicity.
- `Storage.Supervisor` runs `:rest_for_one` with `max_restarts: 10, max_seconds: 60` — Holder + WAL + Sealer + Runner + Checkpointer + Replication.Nonces start in that declared order and restart in the same order after failures. The same `10/60` budget is mirrored on the other 3 domain supervisors so a tight crash-loop terminates the BEAM rather than thrashing the WAL / signing state.

**Replicator** — bidirectional peer-to-peer WAL tail
- One Replicator GenServer runs on every node. It tracks a per-peer cursor and tails each peer's WAL independently.
- Each tick, for each peer, it RPCs that peer's `Storage.Replicator.entries_since/1` with an HMAC-signed `Replication.Auth` request (cursor + nonce + timestamp), validates the signed response, checks per-origin seq monotonicity across the returned batch BEFORE any WAL write (catches a compromised peer injecting backward-seq entries), appends each entry to the local WAL, then dispatches to `Markets.Facade.replicate_entries/1`, `Federation.Facade.replicate_entries/1`, and `Identity.Facade.replicate_entries/1` for ETS application.
- Emits a `[:perp_walk, :storage, :replicator, :tick]` telemetry event per tick per peer carrying `{cursor, peer_tip, lag, batch_size, result}`; the `Telemetry.Health.Cache` consumes it and the `:peer_replication_lagging` (warn) and `:peer_replication_lagging_critical` (critical) alert rules fire from it.
- Cursors are plain entry counts per peer, persisted via atomic tmp+rename with `chmod 0o600`. `:erlang.binary_to_term(_, [:safe])` per AGENT.md.
- All three nodes accept local writes; an entry written on any node propagates to the other two by next tick. Three nodes → three live WAL copies, each lagging the others by at most one tick.

**Replication.Auth** — HMAC-SHA256 over the replication RPC. Distinct shared secret (`:replication_secret`) from federation RPC, distinct version-prefixed message format. Single-method scope by design; any future replication RPC must add method-binding to the HMAC.

**Replication.Nonces** — `:ets.insert_new`-backed single-use nonce cache. Fails closed on cache unavailability (replay protection is load-bearing). The sweep runs on a `@sweep_interval_ms 60_000` tick; the cutoff is `Storage.Replication.Auth.clock_skew_ms() * 2` so nonces are only reaped once the matching freshness gate has already stopped accepting them.

## Commands

| Command | Description |
|---------|-------------|
| Append WAL entry | Write typed record, fsync per policy |
| Replay WAL | Rebuild ETS state from log on startup |

## Boundaries

**Owns**: WAL file lifecycle, ETS table ownership, DETS persistence, recovery logic

**Depends on**: Nothing — Storage is a leaf dependency

**Depended on by**: Markets and Federation use `Storage.Facade.seal_and_append/2,3` for typed entries. Telemetry reads `*_dir/0` paths for backup-age / disk-usage health checks. Storage.Replicator reaches into `Markets.Facade.replicate_entries/1` and `Federation.Facade.replicate_entries/1` (NOT the Stores directly) when applying replicated entries from peers.

## Published Language (Storage.Facade)

External callers interact with Storage exclusively through `PerpWalk.Storage.Facade`:

- **WAL**: `seal_and_append/2,3` (cross-domain entry point — allocates seq via the Sealer and appends), `seal/1` (allocate seq without appending, for callers that need the seq up front), `current_wal_seq/0`, `bump_wal_seq/1`, `read_all_wal/0`, `wal_info/0`
- **Paths**: `base_dir/0`, `backup_dir/0`, `identity_dir/0`, `markets_dir/0`, `monero_dir/0`, `monero_orphans_path/0`, `federation_dir/0`, `telemetry_dir/0`, `keys_path/0`, `key_file/1`, `reserves_proofs_path/0`, `ensure_dirs!/0` — domain-scoped data directories so domains don't import `Storage.Paths` directly
- **Encryption**: `encrypt/1`, `decrypt/1`, `encrypt_term/1`, `decrypt_term/1` — wraps the operator-passphrase-derived AES-GCM cipher used for at-rest material (Reserves Nostr signing key, etc.)

Per-aggregate CRUD (markets, positions, votes, payout requests) lives on each *domain's* Facade and Store, not Storage.Facade. Storage owns the substrate; domains own their entities.

**WAL-facade exemption**: Domain Stores that own a WAL server (`Markets.Store`, `Federation.Store`) call `Locker.WAL.append/2` directly rather than routing through `Storage.Facade.seal_and_append/2`. The Facade is not a bypass concern in this case — the Store *is* the writer, the Facade is the cross-domain entry point. These Stores allocate seq through the same Sealer surface.

## Events

Storage publishes no domain events of its own. State changes flow through the WAL itself; cross-domain observers subscribe to the per-domain events (Markets / Federation / Reserves) that the WAL records. Replication-related failures surface through `Logger` warnings and the Telemetry alert path, not a domain event.

**Consumes**: None — Storage is the substrate, not a reactor

## Invariants

- Every state-changing operation MUST write to the WAL before returning success
- WAL entries MUST have monotonically increasing sequence numbers
- The replay MUST be deterministic — replaying the same WAL twice produces identical ETS state
- A corrupt WAL entry MUST halt startup rather than silently skip the entry
- No Ecto, no PostgreSQL, no migrations

---
