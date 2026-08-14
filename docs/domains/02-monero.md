# PERP WALK — Monero Domain

XMR custody and movement. Per-trade subaddresses for inflows; 2-of-3 federated multisig for outflows.

---

## Purpose

The Monero domain is PERP WALK's interface to the Monero blockchain. It wraps the federation's `monero-wallet-rpc` (via `Darks.Client`) to:

- Mint fresh subaddresses for every Quote, every dispute, and every market creation deposit (custody minimisation — no aggregated user balances)
- Detect deposits at the configured confirmation depth and call back into Markets to fill quotes / confirm market deposits / confirm dispute deposits
- Record unattributable deposits (orphan subaddresses, overpayments) in a DETS-backed `Orphans` ledger so the operator has an actionable record rather than silent loss
- Expose the wallet's primary balance and address (consumed by the [Reserves domain](08-reserves.md) for the proof-of-reserves cycle)

Outflows are NOT handled here — they go through the [Federation domain](07-federation.md), which orchestrates the 2-of-3 multisig signing protocol via `Darks.Multisig`. The Monero domain only handles the inflow / observation side and the per-node wallet RPC. Proof-of-reserves orchestration is owned by the [Reserves domain](08-reserves.md).

PERP WALK uses **per-trade subaddresses** for every XMR movement: every Buy click mints a fresh deposit address, every dispute mints its own, every market creation deposit mints its own. There is no aggregated user balance. The platform only holds funds during in-flight Quotes, open Positions, awaiting-deposit / live disputes, and creation deposits — not as idle user-held balance. See `project_perp_walk_money_flow` memory for the rationale.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **monerod** | The full Monero node daemon (pruned in production) |
| **monero-wallet-rpc** | The wallet daemon. Each guardian runs its own; together they hold the 2-of-3 multisig. |
| **Subaddress** | A cryptographically unlinkable receive address derived from the primary multisig wallet |
| **Confirmation** | Block depth required before a deposit triggers Markets-side state changes (default: 10 — `@default_confirmations` in `Monero.Poller`, configurable via `[:perpwalk, :monero_poller, :confirmations]`) |
| **View key** | Allows reading transactions without spending — may be published for transparency |
| **Spend key** | Required to authorize outgoing transactions. Distributed as multisig key shares across the federation; no single key exists |
| **Poller** | The `Monero.Poller` GenServer that polls `get_transfers` and dispatches confirmed deposits to the right Markets entry point based on the destination subaddress |

## Aggregates

**Wallet** (federation-level singleton, three key shares)
- A single 2-of-3 multisig Monero wallet shared across all three guardians
- Each node holds its own key share via `Cartel.KeyStore` (AES-256-GCM at rest, PBKDF2-derived key)
- Outflows require any 2 of the 3 nodes to co-sign via `Darks.Multisig.export_info / import_info / sign / submit`

**Subaddress allocation** — `Monero.Facade.create_subaddress/0`
- Calls `Darks.Client.create_address/1` against the wallet RPC
- Returns `{:ok, %{address: addr, address_index: idx}}`
- Used by Markets services for every Quote, every dispute, every market creation deposit

**Poller** — one GenServer per node
- Polls `monero-wallet-rpc.get_transfers` at a configurable interval. Every guardian's Poller runs, so reorg detection and unconfirmed-drop detection happen everywhere.
- Ledger-mutating dispatch (fills / confirmations / orphan writes) is gated on `Role.designated_processor?()` — only the designated processor writes; the other guardians publish local UI signals (e.g. `QuoteUnderpaid` for the modal transition) but skip the ledger call. The processor's writes reach the other guardians via bidirectional WAL replication, so two nodes never credit the same deposit.
- For each confirmed transfer at the configured depth, resolves the destination subaddress via `lookup_subaddress/1` (O(1) via the `Markets.Store` subaddress secondary indexes) and dispatches:
  - `{:ok, {:quote, quote_id}}` → `Markets.Facade.fill_quote/2`. Overpayments are filled at the locked quote price and the overage is recorded as an `:overpayment` orphan for manual operator refund.
  - `{:ok, {:dispute, account_id, market_id}}` → `Markets.Facade.confirm_dispute_deposit/2`
  - `{:ok, {:market_deposit, market_id}}` → `Markets.Facade.confirm_market_deposit/1`
  - `{:ok, {:orphan, subaddress_index}}` → `Orphans.record(:unmatched_subaddress, ...)` — a non-zero subaddress that no active record claims (e.g. user paid into an expired quote's subaddress). Without this fallback Darks would silently drop the deposit, leaving funds in the wallet with zero application-level record.
- Underpaid deposits do NOT trigger the Markets-side fill / confirmation (the user paid less than the locked quote price or dispute stake). The deposit is logged and recorded as an `:underpayment` orphan so the operator can refund via `Federation.Console` rather than the funds being invisible until someone tails logs.
- Quote fills that pass the amount check but fail the Markets-side `fill_quote/2` (expired quote, AMM price moved past the locked amount, source side ran dry) are recorded as `:fill_failed` orphans alongside the warning — the deposit is real money in custody on a known subaddress.
- On reorg / unconfirmed-drop the poller calls `Federation.Facade.halt_signing/0` and `Federation.Facade.record_audit/2` so the federation freezes and the event is durably logged

**Orphans** — DETS-backed unattributed-deposit ledger
- Records every deposit that cannot land on a Markets-side fill / confirmation: `:unknown_quote`, `:unknown_dispute`, `:unknown_market_deposit`, `:unmatched_subaddress`, `:overpayment`, `:underpayment`, `:fill_failed`
- Idempotent on `txid`; publishes `OrphanDepositObserved` so the operator dashboard surfaces the entry
- Operator review via `Orphans.list/0` and resolution via `Orphans.mark_resolved/1` after manual refund

**Adapters: Darks.Client** — anti-corruption layer for `monero-wallet-rpc` calls (balance, height, create_address, get_transfers)

## Commands

| Command | Description |
|---------|-------------|
| Create subaddress | Mint a fresh single-use subaddress for a specific purpose (Quote, dispute, market deposit) |
| Detect deposit | Poller callback path; on confirmation, dispatch to the appropriate Markets entry point |
| Expose wallet primary / view-key / balance | Read-only inputs to the Reserves domain's proof cycle |
| Health check | Probe `monerod` and `wallet-rpc`; surface failures via Telemetry alerts |

## Boundaries

**Owns**: Per-node wallet RPC connection, subaddress allocation, deposit polling, deposit-to-Markets dispatch routing

**Depends on**:
- External: `monerod` (full node) and `monero-wallet-rpc` (signing daemon, one per guardian) — co-located on each guardian host
- `darks` package — `Darks.Client` for wallet RPC, `Darks.Multisig` for the multisig protocol (used by Federation, not Monero directly)
- `Markets.Facade` — the dispatch targets for confirmed deposits

**Depended on by**:
- Markets services (`Maker`, `Trader`, `Disputer`) — call `Monero.Facade.create_subaddress/0` to mint per-purpose subaddresses
- `Reserves.Source` — calls `Monero.Facade.balance/0` for the assets side of each proof cycle

## Published Language (Monero.Facade)

- `health_check/0` — probe `monerod` + wallet-rpc
- `balance/0` — wallet primary balance (consumed by `Reserves.Source.reserves/0` and TVL display)
- `address/0` — primary account address of the currently-open wallet (used by `Federation.Facade.verify_multisig_address/0` and the `Multisig.Guard` watchdog)
- `block_height/0` — current chain tip from the wallet's view
- `create_subaddress/0` — mint a fresh subaddress (returns `{:ok, %{address, address_index}} | {:error, reason}`)

The synchronous single-key `transfer/2` previously exposed for "just send some XMR" calls has been removed. Every Monero outflow MUST go through 2-of-3 multisig via `PerpWalk.Federation.Facade.enqueue_payout/3` — exposing a direct facade was a footgun (AGENT.md money-path invariant: no synchronous single-key transfer).

No other Monero module is imported by any other domain.

## Events

**Publishes**: The Poller emits `MarketDepositObserved` on first sighting of a market-creation deposit (pre-confirmation; UI greys the deposit QR) and `OrphanDepositObserved` on unattributable deposits — both live under `PerpWalk.Events.Markets` as cross-domain events surfaced on the operator dashboard. Deposit attribution itself dispatches through synchronous facade calls (`Markets.Facade.fill_quote/2`, `confirm_dispute_deposit/2`, `confirm_market_deposit/1`). Wallet reachability is alerted through Telemetry.

**Consumes**: None directly — the Poller is driven by its own tick.

## Invariants

- The wallet primary spend key MUST exist only as 2-of-3 multisig key shares — no single party holds full spend authority
- Each node's key share MUST be encrypted at rest via `Cartel.KeyStore` (AES-256-GCM, PBKDF2-derived from a per-node passphrase)
- The view key MAY be published; the spend key shares MUST NEVER be published
- Subaddresses MUST be unlinkable to the primary wallet address (Monero's native property)
- Deposits MUST require the configured confirmation depth before triggering a Markets-side state change (default: 10 confirmations, configurable via `[:perpwalk, :monero_poller, :confirmations]`)
- An underpaid deposit MUST NOT trigger a Markets-side fill / confirmation — log, record as an `:underpayment` orphan, and skip the fill so the operator has an actionable refund path
- All `monerod` / `wallet-rpc` failures MUST be wrapped by error handling; persistent failures trigger Telemetry alerts and may halt auto-signing

---
