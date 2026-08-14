# PERP WALK — Reserves Domain

Proof-of-reserves cycle. Snapshots the federation multisig balance against worst-case open-position liability and publishes signed attestations to three independent verification surfaces.

---

## Purpose

The Reserves domain produces tamper-evident solvency proofs on a fixed cadence. Each cycle:

1. Reads the federation multisig balance (assets) and the live position table (liabilities).
2. Bundles them into a canonical proof structure.
3. Collects per-peer attestations from federation members (each peer signs after re-deriving the snapshot from its local state — divergence aborts the cycle).
4. Signs the assembled proof with the issuing node's Ed25519 key.
5. Publishes via three independent surfaces: the `/api/reserves` endpoint, NIP-33 replaceable Nostr events, and the on-chain multisig wallet itself.

The threat the domain defends against: silent insolvency. A user trusting the platform's multisig to back their open position has no way to detect divergence between *what we say we hold* and *what we actually hold* unless that claim is published, signed, and independently checkable. Three surfaces prevent any single censorship vector — taking down the API doesn't take down Nostr; taking down our Nostr doesn't take down the on-chain reality.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Reserves** | The federation multisig wallet's confirmed XMR balance |
| **Liabilities** | Worst-case payout obligation across all open positions and pending refunds |
| **Solvency** | `reserves >= liabilities`. The proof reports the delta and the percentage |
| **Snapshot** | A point-in-time `(reserves, liabilities, asset_ids)` tuple, canonical-encoded |
| **Attestation** | A peer's Ed25519 signature over the snapshot, indicating that peer re-derived the same numbers from its local state |
| **Proof** | The full assembled structure: snapshot + attestations + issuing-node signature + cycle metadata |
| **Cycle** | One proof generation pass: snapshot → attest → sign → evaluate → publish |
| **Publisher** | A target the proof gets pushed to. Three configured: PubSub (admin dashboard), Nostr relays, the on-chain wallet (passive — the wallet is the wallet) |
| **NIP-33 replaceable event** | Nostr kind 30078, where the latest event with a given `(pubkey, d-tag)` supersedes earlier ones. The `d-tag` namespaces by cycle so historical proofs stay queryable |
| **piconero** | Atomic XMR unit (1 XMR = 1_000_000_000_000 piconero). All public values are piconero-suffixed |

## Aggregates

**`PerpWalk.Reserves.Source`** (`Vault.Source` impl)
- Pure read against existing domain state, routed through `Markets.Facade` and `Monero.Facade` (no direct Store imports). No persistence.
- `reserves/0` → multisig wallet's full `balance` (confirmed unlocked + confirmed locked) via `Monero.Facade.balance/0`. `unlocked_balance` was the original choice but produced false-positive deficit alerts on every payout (locked change output drops `unlocked_balance` by the full input for ~10 blocks) and every deposit (the ~10-block lock window leaves the incoming amount in `balance` but not yet in `unlocked_balance`); `balance` keeps held and outstanding in lockstep through both lifecycles. Residual risk: brief false-surplus from unconfirmed deposits in `balance`; the trade-off is documented inline in `Source.reserves/0`.
- `liabilities/0` → sum across three sources:
  - **Position obligations** — open positions are grouped per market by side; the market contributes `max(yes_total, no_total)` because only one side can win. `:settled_winner` adds `contracts × unit_size` on top (the post-settle, pre-payout claim); `:refunded` adds `amount_paid` (refund Payout pending); other statuses contribute 0. The earlier "sum both sides" formula over-stated lopsided markets by `min(yes_total, no_total)` and tripped false-positive deficits when a small wallet covered the real max payout but not the inflated sum.
  - **Dispute refunds pending** — `:resolved_for` / `:resolved_against` disputes whose refund Payout hasn't landed yet still owe `Dispute.refund_amount_piconeros/1`
  - **Creator LP capital still in custody** — `:voided` markets owe the full `deposit_amount` back until `creator_lp_paid_out_at` is stamped by the Signer post-submit; `:settled` markets owe the winning-side residual (`pool.<outcome> × unit_size`) until the same flag is stamped. Other statuses contribute 0 (either active LP capital covered by trader-side outstanding, or rejected → house revenue).
- `asset_ids/0` → ids of markets in `:active | :expired | :resolving` (the markets that drive the liability total)
- Conservative direction: liabilities favour over-statement over under-statement (creator-LP and dispute-stake conservatism, plus the `:settled_winner` overlap with the LP residual). Over-stating liabilities is the safe direction for a solvency proof.

**`PerpWalk.Reserves.Snapshot`** (translation helper, pure module)
- Single point of translation between Vault's `_sats`-keyed snapshot fields and PERP WALK's `_piconeros`-keyed public surface. Vault was originally written for Bitcoin; PERP WALK is Monero-denominated. The math is identical, only the naming differs.
- `to_piconeros/1` produces the piconero-keyed shape consumed by every public surface (HTTP `/api/reserves`, NIP-33 Nostr content, admin solvency widget). If Vault grows a new `_sats`-suffixed field, only this module needs updating.
- `solvency_pct/1` clamps `held / outstanding * 100` to `[0, 999]`; `999` represents "effectively infinite coverage" (outstanding == 0).

**`PerpWalk.Reserves.Signer`** (Ed25519)
- Signs the canonical proof bytes with the node's local Ed25519 key.
- Multi-party validation comes from peer attestations gathered before this signer runs — the signature here commits the issuing node to the assembled proof.
- Not a threshold signature; the threshold proof is the attestation set.

**`PerpWalk.Reserves.Publishers.Event`**
- Broadcasts `Events.Reserves.ProofGenerated` over the internal PubSub bus so the admin dashboard renders the latest proof live.

**`PerpWalk.Reserves.Publishers.Nostr`** (GenServer)
- Owns the secp256k1 signing key (encrypted at rest via `Storage.Facade.encrypt/decrypt`).
- Builds NIP-33 events (kind 30078) over the proof.
- Signs via `PerpWalk.Crypto.Schnorr` (BIP-340 over the canonical event bytes).
- Pushes to configured relays via `PerpWalk.Nostr.Relay.Client` over the Tor HTTP CONNECT tunnel.

**`PerpWalk.Reserves.Publishers.Vault`**
- Thin wrapper that delegates to the Nostr publisher; the indirection lets `Vault.Generator` treat all publishers uniformly without learning Nostr-specific concerns.

**`PerpWalk.Crypto.Schnorr`** (adapter)
- Wraps the Cashew NIF for BIP-340 Schnorr signing on secp256k1.
- The Cashew library is a Cashu BDHKE implementation that exposes general-purpose secp256k1 primitives. Routing calls through this adapter keeps the Cashu-flavored naming contained to one file — a future migration to a dedicated secp256k1 library is a one-file swap.

## Commands

| Command | Path | Description |
|---------|------|-------------|
| Generate proof | `Vault.Generator` (timer) | One cycle: snapshot → attest → sign → publish |
| Read solvency | `Reserves.Facade.solvency/0` | Latest proof's reserves / liabilities / delta / pct |
| Latest proof | `Reserves.Facade.latest_proof/0` | Full `Vault.Proof` struct |
| List historical proofs | `Reserves.Facade.proof_history/1` | Up to `limit` proofs from DETS, newest first |
| Publisher pubkey | `Nostr.Facade.venue_pubkey/0` | Hex-encoded BIP-340 x-only secp256k1 pubkey used to sign NIP-33 events (owned by the Nostr domain) |
| Guardian pubkey | `Reserves.Facade.guardian_pubkey/0` | Hex-encoded Ed25519 pubkey used to sign `threshold_signature` over `Vault.Proof.canonical_bytes/1` |
| Capture snapshot | `Reserves.Facade.capture_snapshot/0` | Held vs outstanding piconeros as observed by this guardian — consumed by federation peer-attestation verification |
| Drift diagnostic | `Reserves.Drift.status/0` | Most recent divergent-peer set from the attestation collector; published-surface Store diagnostic per the AGENT.md carve-out |

## Boundaries

**Owns**:
- `Reserves.Source` (Vault.Source impl)
- `Reserves.Signer` (Ed25519)
- `Reserves.Publishers.Event` / `Nostr` / `Vault`
- `Reserves.Facade` (public reads)
- `Reserves.Supervisor` (cycle wiring)
- `PerpWalk.Crypto.Schnorr` adapter
- Nostr relay publishing (routed via `PerpWalk.Nostr.Facade.publish_event/2`)
- The Nostr signing key (encrypted at rest)

**Depends on**:
- `vault` package — `Vault.Source`, `Vault.Generator`, `Vault.Proof` types and the cycle orchestration
- `cashew` (via the Schnorr adapter) — secp256k1 + BIP-340 primitives
- `Monero.Facade.balance/0` — the assets side of the snapshot
- `Markets.Facade.list_all_positions/0`, `list_markets/0`, `list_disputes/0` — the liabilities side
- `Storage.Facade` — `keys_path/0`, `reserves_proofs_path/0`, `encrypt/decrypt` for key material at rest

**Does not own**:
- Custody (Federation owns the multisig)
- The on-chain wallet (Monero domain owns the RPC; Federation owns the keys)
- Position state machine (Markets owns it; Reserves only reads)

## Published Language (PerpWalk.Reserves.Facade)

External callers interact through `PerpWalk.Reserves.Facade`:

- `solvency/0` — current snapshot: `:active | :pending` status, held / outstanding / delta in piconeros, percentage. Routed through `Reserves.Snapshot.to_piconeros/1` so the public shape stays consistent across surfaces.
- `latest_proof/0` — full `Vault.Proof` struct (used by the Nostr publisher and the admin dashboard)
- `proof_history(limit)` — up to `limit` historical proofs from DETS, newest first
- `platform_revenue_piconeros/0` — cumulative federation revenue (slashed dispute stakes + forfeited creator deposits + house spread share)
- `guardian_pubkey/0` — hex-encoded Ed25519 pubkey used to sign each proof's `threshold_signature`. The Nostr publisher pubkey lives on `Nostr.Facade.venue_pubkey/0` in the Nostr domain.
- `capture_snapshot/0` — held vs outstanding piconeros as observed by this guardian; consumed by federation peer-attestation verification

## Surfaces

Three independent verification paths:

| Surface | Endpoint | Cadence | What it proves |
|---------|----------|---------|---------------|
| HTTP | `/api/reserves` (`/api/reserves/history` for history) | On-demand | The platform's current claim. JSON keys are all piconero-suffixed; response includes the publisher + guardian pubkeys for client-side signature verification. |
| Nostr | NIP-33 kind 30078 events to configured relays | Each cycle (default 60s) | Tamper-evident historical record outside our infrastructure. Per-cycle `d-tag` so historical proofs stay queryable. |
| On-chain | The federation multisig wallet itself | Continuous | Ground truth — the actual balance. Monero's view-key is NOT currently published by the application; on-chain verification requires the wallet's view-key supplied out-of-band. |

## Events

**Publishes**:
- `Events.Reserves.ProofGenerated` — fires on every successful cycle; carries the proof. Consumed by the admin dashboard.

**Consumes**:
- None directly. The cycle is timer-driven via `Vault.Generator`.

## Invariants

- A proof MUST NOT be published unless the issuing node's local re-derivation of `(reserves, liabilities)` matches every peer's attested re-derivation byte-for-byte.
- The multisig balance read MUST come from `Monero.Facade.balance/0` (the `balance` field — see `Source.reserves/0` for the documented trade-off vs `unlocked_balance`). Mempool entries may briefly appear in the surplus direction; the deficit direction is the safety-critical one and `balance` is monotone with respect to locked change.
- Liabilities MUST be over-stated rather than under-stated. Open positions count the per-market max-payout side (not the sum of both); `:settled_winner` plus the LP residual produces a temporary double-count between settle and payout that errs on the safe side. A proof reporting solvency on over-stated liabilities is unambiguously sound.
- The Nostr signing key MUST be encrypted at rest. Key generation, persistence, and decryption MUST flow through `Storage.Facade.encrypt/decrypt`.
- A proof's NIP-33 `d-tag` MUST be unique per cycle (so historical proofs stay queryable) but the `kind` (30078) MUST stay constant (so subscribers can filter without per-cycle reconfiguration).
- The proof generation cycle MUST halt if `Federation.Signer.halted?` returns true — operator halt suspends both signing and reserve attestation.

## Restart Strategy

`Reserves.Supervisor` runs `:rest_for_one`: if the Nostr publisher crashes, the `Vault.Generator` restarts alongside it so the publishers list re-resolves cleanly. A bug in the Nostr publisher cannot leave the generator stuck pointing at a dead process.

## Open Questions

- **Adversarial attestation**: peers attest by re-deriving from local state. A peer with stale state (replication lag) would refuse to attest, halting the cycle. Acceptable failure mode — the alternative is publishing proofs with stale data.
- **Relay mix**: configured relay set is operator-controlled. A future improvement is a per-cycle randomised subset to make censorship of the historical record require coordinated relay-by-relay takedown.
