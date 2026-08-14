# PERP WALK — Events Domain

Cross-domain communication via a typed EventBus. Decouples publishers from consumers.

---

## Purpose

Domains MUST NOT call each other's internal modules. They communicate via two channels:

1. **Facades** — synchronous, typed entry points for direct work (e.g. Markets calling `Monero.Facade.reserve`)
2. **EventBus** — asynchronous, typed publish/subscribe for fan-out and cross-cutting concerns (Telemetry observation, audit logs, dashboard ticker)

This domain owns the EventBus, the event taxonomy, and the `Display` protocol used to render any event into a human-readable description for logs, dashboards, and Nostr DMs.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Domain event** | A typed struct describing something that happened in a domain (e.g. `Markets.MarketSettled`) |
| **EventBus** | The publish/subscribe mechanism — Phoenix.PubSub under the hood |
| **Topic** | A logical channel — typically the event module name |
| **Display** | A protocol implemented by every event struct, dispatching to four functions: `domain/1` (the originating domain atom), `label/1` (short event name), `severity/1` (`:info | :warning | :critical | :emergency`), `detail/1` (a human-readable detail string) |
| **Subscriber** | A process that joins a topic and receives events as messages |
| **Audit trail** | The full history of domain events written to the WAL by Storage |

## Aggregates

**EventBus** (singleton)
- Wraps Phoenix.PubSub with a typed interface
- `publish/1` → broadcasts on the base topic derived from the struct module
- `publish/2` → broadcasts on `"base:<suffix>"`, used for aggregate-scoped streams (e.g. a single market id) so subscribers can scope their inbox to one entity
- `subscribe/1` / `unsubscribe/1` → join / leave the base topic for an event type
- `subscribe/2` / `unsubscribe/2` → join / leave a per-instance suffixed topic for a specific aggregate

**Display** (protocol)
- Every domain event implements `Display`, dispatching to four functions: `domain/1`, `label/1`, `severity/1`, `detail/1`
- Used by Telemetry's event stream, the admin dashboard, and Nostr publishers

**Per-domain catalog modules** — `PerpWalk.Events.Markets`, `PerpWalk.Events.Federation`, `PerpWalk.Events.Telemetry`, `PerpWalk.Events.Reserves`
- Define the canonical event struct for each domain in one file per domain
- Serve as the contract between publishers and consumers

## Commands

| Command | Description |
|---------|-------------|
| Publish event | Broadcast a typed event to all subscribers of its topic |
| Subscribe to topic | Process joins a topic and receives events as Erlang messages |
| Render event | Convert an event struct to a human-readable tuple via the Display protocol |

## Boundaries

**Owns**: EventBus implementation, topic naming convention, Display protocol, the canonical event type registry

**Depends on**:
- `Phoenix.PubSub` — the underlying transport

**Depended on by**: Every domain (publishers and subscribers)

## Published Language (Events.EventBus)

The complete public API:

- `EventBus.publish/1` — broadcast the event on its base topic
- `EventBus.publish/2` — broadcast on `"base:<suffix>"` for aggregate-scoped streams
- `EventBus.subscribe/1` / `unsubscribe/1` — join / leave the base topic
- `EventBus.subscribe/2` / `unsubscribe/2` — join / leave a per-instance suffixed topic
- `Display.domain/1`, `Display.label/1`, `Display.severity/1`, `Display.detail/1` — protocol dispatch for human-readable rendering

## Events

This domain is the substrate; it owns no domain events of its own. The events catalog is maintained per-domain and referenced from this document.

### Markets domain events

Lifecycle: `MarketCreated`, `MarketDepositObserved` (first mempool/unconfirmed sighting of the creator deposit — UI greys the deposit QR; consumed by `MarketNewLive` to update modal state), `MarketDepositConfirmed` (confirmation threshold met — `:awaiting_deposit → :pending`; `MarketNewLive` auto-closes the modal and navigates to the market detail), `MarketActivated`, `MarketRejected`, `MarketExpired`, `MarketSettled`, `MarketVoided` (carries `reason: :operator | :creator_no_show | :guardian_undecidable`)

Trades: `QuoteCreated`, `QuoteDepositObserved` (first sighting of a trade-deposit subaddress hit — UI greys the QR), `QuoteFilled`, `QuoteUnderpaid` (confirmed deposit landed under the locked quote price — the fill is skipped and a `:quote_underpayment_refund` payout is queued so the underpaid amount routes back to the sender), `PositionOpened` (legacy), `PositionPaidOut`, `PositionCancelled`

LP: `CreatorLpReturned` (creator's LP residual / void return has been paid out — `creator_lp_paid_out_at` stamped post-Signer-submit, drops the market from the Reserves liability total)

Resolution: `ResolutionSubmitted`, `ResolutionReversed`

Disputes: `DisputeDepositObserved` (first sighting of a dispute-stake deposit — UI greys the stake QR), `DisputeFlagged` (deposit confirmed, dispute is now `:live`), `DisputeReReviewTriggered` (fires once per ack cycle when live count crosses threshold), `DisputesAcknowledged` (guardians cleared the settle gate), `DisputeResolved` (terminal per-dispute; carries `:resolved_for | :resolved_against`, refund amount, slashed amount)

Federation-revenue source: `DepositBurned` (creator's deposit forfeited on `:rejected` — funds accrue to the federation-revenue ledger)

Comments: `CommentReceived` (a verified Nostr comment event referencing one of the venue's markets was ingested by `Markets.Comments.Inbox`; carries `event_id`, `market_id`, `author_pubkey`, `content`, `created_at`; fires exactly once per distinct event_id since the Inbox dedups relay echoes)

Cross-domain: `OrphanDepositObserved` — published by `Monero.Orphans` when a confirmed deposit is recorded against an unmatched subaddress, an overpayment, or any other unattributable case. Lives under `PerpWalk.Events.Markets` for historical reasons (Markets is the consumer that surfaces orphans on the operator dashboard); semantically a Monero-side event.

### Monero domain events

Monero publishes no events of its own. Deposit attribution flows through synchronous facade calls (`Markets.Facade.fill_quote/2`, `Markets.Facade.confirm_dispute_deposit/2`, `Markets.Facade.confirm_market_deposit/1`) and the cross-domain `Markets.OrphanDepositObserved` above. Outflows are owned by Federation, so withdrawal-related events live there (`Federation.PayoutSubmitted`, `PayoutFinalizeFailed`, etc.).

Wallet-reachability is surfaced through Telemetry alerts, not domain events.

### Reserves domain events

`ProofGenerated` (every successful proof cycle; carries `proof_id`, `status`, `ratio`, `timestamp`), `ReserveDeficit` (liabilities exceed reserves), `ReserveCriticalDeficit` (deficit past the critical threshold), `ReserveRecovered` (deficit cleared). The dashboard subscribes to `ProofGenerated` for live solvency rendering; Telemetry consumes the deficit events for alerting.

### Identity domain events

Identity publishes no events — see [03-identity.md](03-identity.md).

### Storage domain events

Storage publishes no events of its own. State changes flow through the WAL itself; cross-domain observers subscribe to the per-domain events (Markets / Federation / Reserves) that the WAL records.

### Telemetry domain events

`SystemStatusChanged`, `AlertFired`, `AlertResolved`, `TorDown`, `TorDegraded`, `TorRecovered`.

### Federation domain events

`PayoutRequested` (carries nullable `position_id` and one of seven `kind` values: `:winner_payout | :refund | :dispute_refund_full | :dispute_refund_partial | :federation_income | :creator_lp_return | :quote_underpayment_refund`), `RuleCheckPassed`, `RuleCheckFailed`, `PayoutSubmitted` (signed tx broadcast, `payout_txid` populated; `position_id` is `nil` for kinds without a per-position scope — `:dispute_refund_*`, `:federation_income`, `:creator_lp_return`, `:quote_underpayment_refund`), `PayoutFailed` (signing or rule-revalidation failed pre-broadcast — no on-chain effect), `PayoutFinalizeFailed` (tx broadcast succeeded but Markets-side bookkeeping failed; carries `payout_txid` and retry context), `OperatorOverride` (audit trail for `Console.force_sign/1`), `SigningHalted`, `SigningResumed`, `BootstrapAddressMismatch` (bootstrap peers converged to different addresses), `MultisigAddressMismatch` (`Federation.Multisig.Guard` detected the open wallet's address has drifted from the configured `:multisig_address` — auto-halts the Signer), `PeerJoined` / `PeerLost` (cartel mesh membership transitions), `QuorumLost` / `QuorumRestored` (federation quorum threshold transitions — `QuorumLost` drives the `:federation_quorum_lost` halt class).

## Invariants

- Domain events MUST be plain structs (no pids, no functions, no resources)
- Every domain event MUST implement the Display protocol
- Publishers MUST NOT depend on the existence of any specific subscriber
- Subscribers MUST tolerate event delivery in any order (no causal ordering guaranteed across topics)
- An event publish MUST NOT block on subscriber processing (fire-and-forget semantics)
- An unhandled subscriber error MUST NOT prevent the event from reaching other subscribers

---
