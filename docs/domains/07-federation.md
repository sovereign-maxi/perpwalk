# PERP WALK — Federation Domain

Threshold-signed custody and signing across three independent operator nodes. Cartel runtime + Darks Monero multisig.

---

## Purpose

PERP WALK runs as a **2-of-3 federation** for the cryptographic operations that matter — every Monero outflow (winner payout, void refund) requires two of three node signatures. The federation runtime is provided by the `cartel` package; the Monero multisig protocol is provided by `darks`. PERP WALK orchestrates the two via `PerpWalk.Federation`.

The threat the federation defends against: a single-server compromise that drains the pool wallet. With 2-of-3 multisig, an attacker who fully owns one node has only one of three signatures — they cannot produce a valid spending transaction. Federation is the load-bearing security control on outflows; rule-gating, audit logs, and operator review are layers on top of it.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Federation** | The three-guardian coalition that signs outflows. All guardians are equal — every guardian is an equal multisig participant AND every guardian accepts local writes that replicate bidirectionally to its peers. Which guardian fronts the public `.onion` is purely a routing decision external to the app. |
| **Guardian** | A federation member — the role/identity. Holds one Monero multisig key share, signs payouts, attests reserves. Every node is a guardian. |
| **Peer** | "Another guardian, from this guardian's perspective." Transport-relationship term used in iteration / broadcast / RPC code paths. |
| **Cartel** | The federation runtime package — cluster mesh, encrypted KeyStore, signed transport, peer health |
| **Darks.Multisig** | Monero-native multisig protocol (`prepare/make/finalize/sign/submit`) — the cryptographic primitive |
| **Payout** | A queued outflow awaiting federation signing. Carries destination, amount, kind, signing state, and either a `position_id` (winner / position refund) or `nil` (dispute refund — sourced by the embedded `(account_id, market_id)` tuple instead) |
| **Payout kind** | `:winner_payout`, `:refund` (position refund on a `:voided` market), `:dispute_refund_full` (`:resolved_against` dispute, no slash), `:dispute_refund_partial` (`:resolved_for` dispute, post-slash refund), `:federation_income` (operator-initiated sweep of accumulated revenue to a guardian-controlled address), `:creator_lp_return` (creator's LP residual on `:settled` or full deposit on `:voided`, paid via `Cashier.claim_creator_lp_return/3` after market termination), `:quote_underpayment_refund` (deposit landed under the locked quote price; the underpaid amount is routed back to the sender via an operator-supplied destination) |
| **Federation income withdrawal** | A `:federation_income` Payout enqueued by an operator via `Federation.Console.withdraw_federation_income/3`. Cross-market — uses `"federation"` as a sentinel `market_id` and skips position/market context. Subject to the standard rules pipeline (cooldown, global rate cap, destination sanity) plus a hard cap at `Markets.Federation.Ledger.withdrawable_piconeros/0` |
| **Rules engine** | Pure module that decides whether a Payout is auto-signable or requires operator review |
| **Quorum** | Two of three signer nodes online and reachable. Without quorum, no payouts can be signed. |
| **Cold operator** | The human operator. Holds no separate cryptographic key (signing requires server keys), but has SSH/admin access to all three nodes for review and override. |
| **Designated processor** | The one guardian currently responsible for driving cluster-state-mutation tasks that must not double-fire: Monero deposit-credit ledger writes, the payout signing-loop, and the market lifecycle scheduler ticks. Defaults to node index 1 (`:p1` in prod, `:s1` in staging). The other guardians still observe the Monero chain (so reorgs are detected everywhere), replay lifecycle events from the WAL, and counter-sign FROST rounds when their share is requested — they simply do not drive the queues themselves. There is no election protocol: the assignment is inventory-default and can be moved at runtime by the operator via `Federation.Console.promote_processor/1`, which WAL-appends a `:processor_promotion` entry that replicates to every guardian so the cluster converges on the new set. Custody and signing are symmetric across all three regardless. |

## Architecture

```
                         PERP WALK Federation
            ┌─────────────────────────────────────────────┐
            │                                             │
            ▼                                             ▼
        Node A  ◀── currently serving .onion         Node B
   (anchor jurisdiction 1)                  (anchor jurisdiction 2)
            │                                             │
            ├─ Cartel.Cluster (mesh)                      ├─ Cartel.Cluster
            ├─ Cartel.KeyStore (share A)                  ├─ Cartel.KeyStore (share B)
            ├─ PerpWalk.Federation.Signer                 ├─ PerpWalk.Federation.Signer
            └─ Darks.Multisig (Monero RPC)                └─ Darks.Multisig
            │                                             │
            └─────────────────┬───────────────────────────┘
                              │
                         Cartel BEAM cluster
                              │
                              ▼
                          Node C
                  (anchor jurisdiction 3)
                              │
                              ├─ Cartel.Cluster
                              ├─ Cartel.KeyStore (share C)
                              ├─ PerpWalk.Federation.Signer
                              └─ Darks.Multisig
```

All three nodes hold identical code, identical config, and identical secrets — the app does not differentiate guardians at the storage or custody layer. Every node holds a multisig key share, runs a Signer GenServer, exposes Monero RPC via `Darks.Client`, and accepts local writes that replicate bidirectionally. Two asymmetries sit on top of this symmetric substrate:

1. **Which node currently hosts the `.onion` HiddenService keypair.** Purely an external routing decision; the app itself doesn't know or care. OnionBalance across all three is a planned post-launch improvement.
2. **Which node is the *designated processor*.** The designated processor is the sole driver of cluster-state-mutation tasks that must not double-fire (Monero deposit-credit ledger writes, payout signing-loop, market lifecycle scheduler ticks). Defaults to node index 1. All three guardians still hold FROST shares and counter-sign when their share is requested — signing quorum is symmetric — and the non-processor guardians still observe the chain, replay lifecycle events, and receive ledger mutations via WAL replication. They simply do not *drive* the queues themselves. Runtime override lands via `Federation.Console.promote_processor/1` as a WAL-appended `:processor_promotion` entry, so the cluster converges on the new designation without redeploy.

Three guardians, different operator aliases, different hosts, different jurisdictions (per the host-layout posture). Failover of the public `.onion` is manual (move the HiddenService keypair, publish the descriptor). The federation signing responsibility is symmetric — any 2 of 3 guardians can complete a multisig round regardless of which is fronting or which is the designated processor.

## Aggregates

**`PerpWalk.Federation.Product`** — minimal `Cartel.Product` implementation; just `use Cartel.Product`. PERP WALK has no product-level mesh messages, so the default no-op `handle_mesh_message/3` from the behaviour is sufficient. The signing flow lives on `Federation.Signer`.

**`PerpWalk.Federation.Signer`** (one GenServer per node).
- Subscribes to `Payout` events.
- Only the **designated processor's** Signer advances the queue — its tick is gated by `Role.designated_processor?()` alongside `Guard.verified?()` and `Facade.quorum?()`. Non-processor guardians run the Signer process for supervision uniformity but their tick short-circuits without touching the queue; they participate in signing rounds only when the processor requests their FROST share via the multisig protocol.
- Runs the `Rules` engine on each request.
- Coordinates the Monero multisig protocol with peers via `Cartel.broadcast/2`.
- When 2 of 3 signers agree, exchanges multisig info via `Darks.Multisig.export_info / import_info / sign / submit`.
- Idempotent: a duplicate request is detected by ID and dropped.

**`PerpWalk.Federation.Rules`** (pure module).
- Deterministic rule engine: same input → same output, on every node.
- Inputs: `Payout` + market state + (optional) position + (optional) dispute.
- Output: `:ok | {:reject, reason}`.
- Rules (six in order): `amount_match`, `position_status`, `market_status`, `destination_sanity`, `cooldown_threshold`, `rate_cap_global`.
- Dispute-refund kinds skip `position_status` and use the dispute's `refund_amount_piconeros/1` for `amount_match`. They accept any `:resolving | :settled | :voided` market — dispute lifecycle is decoupled from market settlement, so a guardian-resolved dispute is refundable as soon as it terminates regardless of whether the market itself has settled.

**`PerpWalk.Federation.Console`** (iex-driven operator tools).
- `list_pending/0` — review queue
- `review/1` — show rule check results for a request
- `force_sign/1` — operator override for a rejected request
- `abort/2` — mark a stuck `:signing`/`:submitted` request `:failed` with an operator reason
- `retry/1` — re-queue a `:failed` request for another sign attempt
- `halt/0` / `resume/0` — emergency halt of all auto-signing and resume
- `rotate_keys/0` — re-runs the multisig setup ceremony
- `income_status/0` — earned / drawn / withdrawable breakdown for federation revenue
- `withdraw_federation_income/3` — enqueue a `:federation_income` Payout sweeping accumulated revenue
- `current_processor/0` — show the currently-designated processor set on every reachable guardian (surfaces any cluster-wide divergence)
- `promote_processor/1` — WAL-append a `:processor_promotion` entry moving the designated-processor role to another guardian (used when the default designated processor is down; the entry replicates so every guardian converges on the new set)

**`PerpWalk.Federation.Signing.Peer.Policy`** (per-peer signing gate, pure module).
- Evaluated BEFORE the peer signs an unsigned multisig tx proposed by a peer (the request originator is whichever guardian Cashier ran on; can be any of the three).
- Three rules: `destination_sanity` (Monero address format + non-empty recipient list), `per_recipient_cap` (default 50 XMR / recipient, positive-integer amounts only), `total_outflow_cap` (default 100 XMR / signing round).
- Operates on the parsed `describe_transfer` output from `Darks.Multisig.describe/1`, not the raw hex.

**`PerpWalk.Federation.Signing.Peer.Throttle`** (per-peer sliding-window cap, GenServer).
- Tracks total signed outflow per peer over a configurable window (default 200 XMR / 6 h).
- Records on every accepted signing round in `RPC.Peer.sign/1` after `Peer.Policy` passes; rejects when a new reservation would push the running total over cap.
- In-memory only — restart resets the window. Defense-in-depth gate; the first-line defense is operator monitoring of `PayoutSubmitted` events.

**`PerpWalk.Federation.Multisig.Guard`** (wallet-address watchdog, GenServer).
- Periodically (60 s default) verifies `Monero.Facade.address/0` matches the configured `:multisig_address`.
- On mismatch: publishes `MultisigAddressMismatch` AND auto-halts the Signer via `Facade.halt_signing/0` so signing stops even when the operator is unreachable.

## Commands

| Command | Description | Path |
|---------|-------------|------|
| Bootstrap multisig wallet | One-time ceremony: prepare → make → finalize across all three nodes | `Federation.Bootstrap`, iex-driven |
| Enqueue position payout | Winner / position refund — Cashier creates a Payout instead of transferring synchronously | `Markets.Services.Cashier.claim_payout/3` → `Federation.Facade.enqueue_payout/3` |
| Enqueue dispute refund | Resolved dispute claim — Cashier creates a Payout with `:dispute_refund_full / :dispute_refund_partial` kind | `Markets.Services.Cashier.claim_dispute_refund/3` → `Federation.Facade.enqueue_dispute_refund/3` |
| Auto-sign Payout | Each node runs Rules, agrees, signs via Darks.Multisig | `Federation.Signer` background |
| Submit signed transaction | Once threshold reached, one node submits via wallet RPC | `Darks.Multisig.submit/1` |
| Finalise Markets-side state | After submission, Signer transitions the source entity: position → `:paid_out` (via `Markets.Facade.mark_position_paid_out/2`), dispute → `:refunded_full / :refunded_partial` (via `Markets.Facade.mark_dispute_refunded/2`) | dispatched by `Federation.Signer` based on Payout kind |
| Force-sign rejected request | Operator override for rule violations | `Federation.Console.force_sign/1` |
| Halt federation signing | Emergency stop for auto-signing, queues everything for operator | `Federation.Console.halt/0` |

## Boundaries

**Owns**:
- Cartel.Supervisor configuration and lifecycle
- The Monero multisig wallet (federated 2-of-3, set up once via `Darks.Multisig`)
- Payout state machine
- Rules engine
- Federation.Signer per-node coordination
- Operator iex tools

**Depends on**:
- `cartel` — federation runtime (`Cartel.Cluster`, `Cartel.KeyStore`, `Cartel.Health.HealthMonitor`, `Cartel.Adapters.Transport`)
- `darks` — Monero RPC + native multisig (`Darks.Client`, `Darks.Multisig`)
- `Markets.Store` — read-only access to positions and markets for rule evaluation
- `Storage.Facade` — durable Payout persistence via WAL

**Depended on by**:
- `Markets.Services.Cashier` — calls `Federation.Facade.enqueue_payout/3` and `enqueue_dispute_refund/3` instead of synchronously transferring
- `Monero.Poller` — calls `Federation.Facade.halt_signing/0` and `record_audit/2` on reorg / unconfirmed-drop detection
- `Telemetry.Health.Cache` — federation status feeds the Markets / System component pips on the admin dashboard

## Published Language (PerpWalk.Federation.Facade)

External callers interact with the federation exclusively through the facade:

- `enqueue_payout(position, amount_piconeros, destination)` — position-sourced Payout (winner / refund)
- `enqueue_dispute_refund(dispute, amount_piconeros, destination)` — dispute-sourced Payout (full / partial)
- `enqueue_federation_income_withdrawal(amount_piconeros, destination, requesting_account_id)` — operator-initiated sweep of accumulated federation revenue
- `federation_income_drawn/0` — sum of non-failed federation-income payouts (consumed by `Markets.Federation.Ledger.withdrawable_piconeros/0`)
- `force_approve(request_id)` — operator override for an `:awaiting_operator` request
- `abort_request(request_id, reason)` — mark a stuck request `:failed` with an explicit operator reason
- `get_request(request_id)` — fetch a Payout by id
- `list_requests*` — queue queries by status, position, or in-flight
- `quorum?/0`, `member_count/0`, `online_peer_count/0`, `threshold/0`, `halted?/0` — runtime status
- `halt_signing/0` — cross-domain entry point for halting auto-signing (used by `Monero.Poller`, `Multisig.Guard`, telemetry)
- `record_audit/2` — cross-domain entry point for the operator-action audit log
- `expected_multisig_address/0` / `verify_multisig_address/0` — bootstrap-time configuration and `Multisig.Guard` cross-check
- `replicate_entries/1` — Storage-domain entry point used by `Storage.Replicator` to apply peer WAL entries

## Events

**Publishes**:
- `Federation.PayoutRequested` — new request entered the queue (carries nullable `position_id`, `kind` ∈ `:winner_payout | :refund | :dispute_refund_full | :dispute_refund_partial | :federation_income | :creator_lp_return | :quote_underpayment_refund`)
- `Federation.RuleCheckPassed` — request cleared all rules
- `Federation.RuleCheckFailed` — request flagged for operator review (carries reason)
- `Federation.PayoutSubmitted` — signed tx broadcast (carries txid; `position_id` nullable for dispute / federation-income refunds)
- `Federation.PayoutFailed` — signing or rule-revalidation failed pre-broadcast — no on-chain effect; request stays in `:rules_passed` for retry
- `Federation.PayoutFinalizeFailed` — tx broadcast succeeded but Markets-side bookkeeping failed; carries the on-chain `payout_txid` so operators don't misread it as a missing payout
- `Federation.OperatorOverride` — request force-signed via the operator console
- `Federation.SigningHalted` / `Federation.SigningResumed` — operator halt control
- `Federation.BootstrapAddressMismatch` — bootstrap peers converged to different addresses
- `Federation.MultisigAddressMismatch` — `Multisig.Guard` detected the open wallet drifted from the configured address; Signer auto-halts

**Consumes**:
- `Markets.MarketSettled` — informational; settlement may produce winners eligible for payout
- `Markets.MarketVoided` — informational; void produces refundable positions
- `Markets.DisputeResolved` — informational; resolved disputes are refundable via `Cashier.claim_dispute_refund`
- Cartel runtime events (`PeerDown`, `PeerRecovered`, `QuorumLost`, `QuorumRestored`) — consumed via `Cartel.Health.HealthMonitor`'s PubSub

## Invariants

- Every Monero outflow MUST be signed by 2 of 3 guardians.
- The Rules engine MUST be pure and deterministic — same input on every guardian yields same output.
- A Payout MUST NOT be marked `:submitted` unless the on-chain transaction has been broadcast by `Darks.Multisig.submit/1`.
- The signing protocol MUST tolerate one guardian being offline at any time without halting the federation. (Two offline simultaneously degrades to operator-only override.)
- Each guardian MUST persist its key share encrypted at rest via `Cartel.KeyStore` (AES-256-GCM, PBKDF2-derived key from per-guardian passphrase).
- Per-guardian passphrases MUST be unique per guardian — a compromise of one guardian MUST NOT yield another guardian's signing key.
- Rule-rejected requests MUST NOT be auto-signed under any circumstance. Override MUST be explicit via `Federation.Console.force_sign/1`.
- Every peer-side signing request MUST pass both `Peer.Policy` (per-transaction caps) and `Peer.Throttle` (sliding-window cap) before reaching `Darks.Multisig.sign/1`. A compromised originating guardian with the RPC secret cannot drive a peer past these gates.
- Bootstrap RPCs (`bootstrap_create_wallet`, `bootstrap_prepare`, `bootstrap_make`, `bootstrap_exchange_keys`) MUST be refused once `:multisig_address` is configured. Post-bootstrap calls return `{:error, :bootstrap_complete}` so a leaked RPC secret cannot replace or corrupt the established multisig.
- Production boot MUST refuse to start when `[:perpwalk, :federation, :peer_nodes_override]` is set — that key is an injection seam for non-production configs and must be `nil` in production.
- A single `:federation_income` withdrawal request MUST be capped to roughly half the remaining available balance. The `amount_match` rule for `:federation_income` checks `requested > earned − drawn` where `drawn` is computed by summing ALL non-`:failed` federation_income payouts INCLUDING the request currently being evaluated; effectively any single request `X` against earned `E` and prior drawn `P` must satisfy `X ≤ (E − P) / 2`. This is an **intentional defense-in-depth control**, NOT a bug — a compromised iex session or misconfigured automated script can move at most half the available balance per request, giving the operator (and peers reviewing `:awaiting_operator` queues) a window to spot anomalies between successive withdrawals. The "own request counts against itself" arithmetic is the security gate. Do NOT "fix" it by subtracting the in-flight request before comparing.

## Threat Model

**Single node compromised**:
- Attacker has 1 of 3 signatures.
- Cannot produce a valid spending transaction.
- Cartel mesh detects misbehaving peer (signed-message replay protection, peer health degradation).
- Recovery: rotate that node's key share via re-running `Darks.Multisig.prepare/make/finalize` with new passphrase on a fresh host; the other two existing keys plus the new one re-establish the 2-of-3 wallet.

**Two nodes compromised simultaneously**:
- Attacker has 2 of 3 — sufficient to drain the pool.
- Made improbable by jurisdictional, operator-alias, and provider separation across all three.
- Detection: `Cartel.HealthMonitor` quorum failure, on-chain anomaly (pool balance dropping unexpectedly), `Federation.PayoutSubmitted` events for unexpected destinations.
- Recovery: bootstrap a new federation with new keys, new aliases, new providers. Lose any in-flight funds.

**All three compromised**:
- Catastrophic. Full reconstitution required.
- Mitigation: operator OPSEC discipline, monitoring (Nostr alerts on every outflow), short residence of in-flight funds (custody minimisation per money-flow architecture).

**No offline operator key**:
- Trade vs the YubiKey/cold-key model: no single human-controlled recovery key, but no key for an attacker to target either.
- Recovery is faster (operator acts via SSH on surviving nodes) at the cost of: no recovery primitive if all three nodes are simultaneously hostile.

## Bootstrap Ceremony

One-time at deployment. Operator-driven via `iex --remsh`:

1. Three nodes are provisioned with `cartel` configured for `n=3, t=2`, each with its own `node_id` (1, 2, 3) and unique `node_passphrase`.
2. Operator exchanges peer public keys out-of-band (each node derives its own via `Cartel.Config.derive_public_key/2`).
3. With all three nodes joined into the Cartel cluster (`Cartel.connected_peers/0` shows the others), operator runs `Federation.Bootstrap.run/0`.
4. The bootstrap orchestrator coordinates the Monero multisig protocol across all three (v0.18 API):
   a. Each node calls `Darks.Multisig.create_wallet/2` to ensure the wallet file exists and is open on its `wallet-rpc`. Idempotent on pre-existing wallets.
   b. Each node calls `Darks.Multisig.prepare/0` → produces its v1 `multisig_info` (public spend share).
   c. Each node calls `Darks.Multisig.make(2, peer_v1_infos)` → produces a v2 info.
   d. Each node calls `Darks.Multisig.exchange_keys(peer_v2_infos)` (the v0.18 replacement for `finalize_multisig`) → produces the shared address. For `M < N - 1` (any 2-of-3 here), one exchange round is sufficient because two v1 rounds already happened above.
5. Resulting state: a single Monero multisig wallet whose primary address is shared. All three nodes have key shares; any 2 can sign.
6. The shared address replaces the previous single-key pool wallet. Existing balance is migrated via a one-time transfer from the old wallet to the new multisig wallet.

Setup ceremony is documented step-by-step in `Federation.Bootstrap` for repeatability.

## Failure Modes

| Failure | Detection | Auto-recovery | Operator action |
|---------|-----------|---------------|-----------------|
| Single peer offline | `Cartel.HealthMonitor` heartbeat timeout | Quorum still met; signing continues | Investigate; restart if needed |
| Two peers offline | `Federation.QuorumLost` event published | All auto-signing pauses | Restore quorum; manual review of any queued requests |
| Wallet RPC unreachable on a node | `Darks.Client.health_check/0` fails | Node degrades; signing rounds time out and retry | Restart `monero-wallet-rpc` |
| Rule engine rejection rate spike | `Federation.Console.list_pending/0` shows growth | None — pile-up is the signal | Review the queue; identify pattern; possibly tighten or loosen rules |
| Disagreement between signers | Signing round produces no agreement after timeout | Round retries; if persistent, request flags for operator | Manual review via Console |

## Open Questions

- **Public-facing failover**: OnionBalance across all three guardians is the planned post-launch improvement. Until it ships, if the front-facing guardian dies the public onion goes dark until the operator republishes the descriptor from a surviving guardian; positions still settle on the surviving WAL because writes replicate bidirectionally. Manual switchover is acceptable at launch scale.
- **Federation membership changes**: Adding a 4th node or rotating one out is a re-ceremony, not a runtime operation. Fine for the launch posture; revisit if scale demands it.
