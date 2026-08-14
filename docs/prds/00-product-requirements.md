# PERP WALK — Product Requirements

Functional requirements, architecture decisions, and system constraints.

---

## 1. Overview

### 1.1 Summary

PERP WALK is a privacy-first prediction market for binary outcome events, settled in Monero. Users deposit XMR per-trade, take positions on community-created markets, and withdraw winnings — all in XMR. No accounts, no KYC, no fiat, no trace. The venue is a Tor hidden service — and only a Tor hidden service. No clearnet, no exceptions. A sovereign signpost points at the onion; see §5.4.

Resolution is **creator-driven** with a 24-hour dispute window: the market creator submits YES or NO at expiry, anyone can stake XMR to dispute the resolution they believe is wrong, and the operator (acting as guardian) acknowledges or reverses. `:void` is operator-only — creators who can't resolve let the deadline lapse and the market auto-voids. Rejected disputes are partially slashed; upheld disputes are fully refunded.

### 1.2 Project Name

- **Public brand**: PERP WALK
- **Tagline**: Markets Without Permission.
- **Mission**: the market for questions other venues won't price.
- **Elixir app name**: `:perpwalk`
- **Release binary**: `perpwalk`

### 1.3 Problem Statement

The Monero community has been explicitly asking for a place to deploy capital. Every existing prediction market is compromised:

| Platform | Problem |
|----------|---------|
| Polymarket | Clearnet, VC-backed, KYC, CFTC settlement, known founders |
| Kalshi | US-regulated, full KYC, limited markets, CFTC-approved only |
| Augur | Dead. Complex, poor UX, requires ETH gas |
| Manifold | Play money. Not real. |

XMR has nowhere to go beyond holding. Every CEX that mattered has delisted it. The community wants utility, signal, and engagement — denominated in their currency, on their terms.

### 1.4 Solution

A prediction market where:

- **XMR only** — All deposits, positions, settlements, and withdrawals in Monero
- **Tor-only transport** — the venue is a `.onion` hidden service. No clearnet surface, no CDN, no exceptions. A sovereign signpost (a static clearnet page hosted on a protected-speech-friendly registrar) points readers at the onion address and carries no operational surface itself.
- **No accounts** — Login via a generated access code, no email, no identity
- **Community markets** — Users create markets on anything: politics, sports, entertainment, crypto, culture
- **Economic moderation** — Bad markets are punished by forfeiture of the creator's deposit (which accrues to federation revenue), not by operator curation
- **Creator resolution + staked disputes** — The market creator picks YES or NO. The community can stake XMR (volume-scaled) to dispute. Rejected disputes lose 50% of stake to the federation; upheld disputes get a full refund. `:void` is operator-only.
- **2-of-3 federated custody** — Hot wallet is a 2-of-3 Monero multisig across three independent nodes (different operator aliases, jurisdictions, providers). Single-node compromise cannot move funds. See [Federation domain](../domains/07-federation.md).
- **Per-trade subaddresses** — Custody minimisation: PERP WALK only holds funds during active positions, not as idle user balances. Every Buy generates a fresh deposit subaddress; the Position only materialises when the deposit confirms. Disputes work the same way — every dispute has its own subaddress.

### 1.5 What This Is NOT

- **Not a derivatives exchange**: No margin, no leverage, no liquidation
- **Not a price market**: No oracles, no automated settlement against external price feeds
- **Not a casino**: Operator clips a spread, doesn't take directional positions long-term
- **Not a DAO**: No governance token, no on-chain voting, no smart contracts
- **Not money transmission**: Users deposit XMR, take positions, withdraw XMR — operator never controls user funds beyond the duration of an open position
- **Not operator-funded liquidity**: Pools are creator-LP-seeded. The operator never deploys capital as market-maker; the creator's deposit IS the pool seed and the creator bears adverse-selection risk in exchange for spread share + LP residual
- **Not continuous-trading**: Markets are unidirectional AMM hold-to-resolution at launch. There is no sell-back to the pool. Bidirectional is post-launch slice only if real demand surfaces

### 1.6 Defensive Posture

PERP WALK's resistance to enforcement is structural, not procedural. Four prongs:

- **No entity** — no LLC, no foundation, no foreign trust. Nothing to subpoena, nothing to seize, nothing to sanction. The federation is a protocol, not a company.
- **No permission** — never asked, never needed. The venue does not request a regulatory exemption because no exemption exists to request. Compliance was never the path.
- **Solved problem on Monero** — transactional opacity isn't a feature claim, it's a property of the substrate. The math does the work the lawyers can't.
- **Jurisdiction doesn't apply** — Tor-only access + Monero-denominated flows + no-entity custody means there is no jurisdictional handle for a regulator to grasp. Procedural service requires an identifiable target, which the architecture does not provide. Even a hostile takedown of the sovereign signpost leaves the `.onion` untouched.

Operator identity is compartmentalised at every layer (different aliases, hosts, jurisdictions, hardware) so single-product enforcement cannot bridge to cross-product exposure.

---

## 2. Users

### 2.1 Primary

| Persona | Need | Behavior |
|---------|------|----------|
| **XMR holder** | Put idle XMR to work | Takes positions on markets they have conviction on |
| **Crypto trader** | Access markets without KYC | Deposits via a BTC→XMR bridge (external), bets, withdraws |
| **Market creator** | Express a view, attract liquidity | Creates markets on topics they care about |
| **Information seeker** | Read odds as signal | Browses markets without taking positions |
| **Community moderator** | Police the platform | Downvotes spam or distasteful markets |

### 2.2 Out of Scope

- Users requiring KYC/AML compliance workflows
- Users expecting fiat settlement
- Users without Tor access
- Users expecting leverage or margin trading

---

## 3. Functional Requirements

### 3.1 User Identity

The access code IS the account. Hashed server-side; raw codes never persisted.

**Flow:**
1. User visits PERP WALK via Tor
2. Clicks "Generate"
3. System generates a 6-word Locksmith keyphrase (e.g. `AMBER-FROST-DELTA-NINE-WOLF-APEX`)
4. User is shown the keyphrase ONCE on `/auth/welcome` with instruction to save it
5. Keyphrase is hashed (Argon2id via `Locksmith.Key.hash/1` — 3 passes, 64 MiB, raw 32-byte tag, hex-encoded) into the `account_id`; the raw keyphrase is never persisted
6. `Identity.Sessions.create/1` mints an opaque server-side `session_id` bound to the `account_id`. A signed Phoenix session cookie carrying ONLY that `session_id` is set; user clicks "I've saved it" to proceed
7. Future visits: user pastes keyphrase at `/auth/login`. Server normalises (trim/uppercase), hashes, mints a fresh `session_id`, sets the cookie.

**Requirements:**
- FR-I01: System SHALL generate access codes as 6-word Locksmith keyphrases (~48 bits entropy)
- FR-I02: Access codes SHALL be derived into the account_id via Argon2id (`Locksmith.Key.hash/1`: 3 passes over 64 MiB, raw 32-byte tag, hex-encoded). The raw keyphrase MUST NOT be persisted. The memory-hard derivation lifts the brute-force floor against a 48-bit keyphrase entropy space to millions of years per account.
- FR-I03: System SHALL display the keyphrase exactly once at generation
- FR-I04: System SHALL NOT provide any recovery mechanism for lost keyphrases
- FR-I05: System SHALL NOT store email, username, IP address, or any identifying information
- FR-I06: System SHALL derive a friendly handle (`adjective-animal-NNNN`) deterministically from the account_id; nothing about the handle is persisted
- FR-I07: Authenticated requests SHALL carry a signed session cookie whose payload is an opaque server-side `session_id`. Possessing the keyphrase is what lets a user obtain a cookie via `/auth/login` or `/auth/generate`. Logout SHALL revoke the `session_id` server-side so the cookie stops working even if its HMAC is still cryptographically valid.

### 3.2 Deposits

PERP WALK uses **per-trade subaddresses** rather than aggregated user balances. There is no platform-managed balance to top up. Every action that requires XMR (taking a position, creating a market, filing a dispute) mints its own deposit Quote with a fresh, single-use subaddress; the action materialises only once the deposit confirms.

**Flow (taking a position):**
1. User clicks Buy with a side and contract count
2. System creates a `Quote` with locked-in price and a fresh per-trade subaddress
3. User sends XMR to the subaddress
4. System detects deposit after the configured confirmation depth
5. Quote consumes into a Position; AMM updates atomically; QuoteFilled emitted

**Requirements:**
- FR-D01: System SHALL generate fresh Monero subaddresses per Quote, per dispute, and per market creation deposit via monerod RPC
- FR-D02: Subaddresses SHALL be unlinkable to each other and to the primary wallet address (Monero's native property)
- FR-D03: Deposits SHALL be credited at the configured confirmation depth (default 10, configurable via `:perpwalk, :monero_poller, :confirmations`). The system SHALL emit `MarketDepositObserved` on the first mempool / unconfirmed sighting of a market-creation deposit (UI greys the deposit QR) and `MarketDepositConfirmed` once the confirmation threshold is met (the state-advancing event that transitions the market `:awaiting_deposit → :pending`). `MarketNewLive` auto-closes the liquidity modal and navigates to the market detail on the latter.
- FR-D04: System SHALL support per-trade deposits from the market's configured `unit_size`
- FR-D05: System SHALL poll the wallet for incoming transfers at a configurable interval
- FR-D06: Deposits SHALL be free (no fee on inflow)
- FR-D07: System SHALL NOT maintain an aggregated user balance — custody is bounded to in-flight Quotes, open Positions, awaiting-deposit / live disputes, and creation deposits

### 3.3 Markets

**Market structure:**
- Description: human-readable statement (e.g., "Will Trump pardon Snowden by July 4 2026?")
- Category: politics, crypto, finance, sports, entertainment, science/tech, culture
- Expiry: timestamp when betting closes
- Resolution: timestamp when operator must resolve (default: expiry + 24h)
- Unit size: configurable per market (default: 0.01 XMR per contract)
- YES and NO contracts priced via constant-product AMM with a 1.5% spread added on every trade (split 1.25% federation / 0.25% creator)

**Requirements:**
- FR-MK01: System SHALL support binary outcome markets (YES/NO) only
- FR-MK02: Every trade SHALL be priced by the FPMM curve with a 1.5% spread collected on top of the fair curve cost (split 1.25% federation / 0.25% creator)
- FR-MK03: Markets SHALL have an expiry timestamp (betting closes)
- FR-MK04: Markets SHALL have a resolution timestamp (the deadline by which the creator must resolve)
- FR-MK05: Markets SHALL belong to a category from a fixed list
- FR-MK06: Users SHALL be able to create markets subject to a creator-paid XMR deposit (configurable)
- FR-MK07: Market creation deposit SHALL be forfeited to federation revenue if the market is community-rejected during the pending window
- FR-MK08: Market creation deposit (LP capital) SHALL be returned as a residual at settlement — equal to `pool.<winning_side> × unit_size` at resolution — via `Cashier.claim_creator_lp_return/3`. The full deposit SHALL be returned only if the market is `:voided`. The creator bears adverse-selection risk on the residual; that risk is the load-bearing economic counterpart to the creator's spread share.
- FR-MK09: Market creator SHALL receive a share of the 1.5% spread on resolution (default split: 1.25% federation, 0.25% creator)
- FR-MK10: Maximum position per user per market: configurable
- FR-MK11: Unit size SHALL be configurable per market

### 3.4 Positions (Betting)

**Flow:**
1. User selects a market and clicks YES or NO with a contract count
2. System mints a `Quote` with locked-in price and a fresh per-trade Monero subaddress
3. User sends XMR to the subaddress
4. Once the deposit confirms (10 confirmations by default), the Quote consumes into a Position; AMM updates atomically
5. Position appears in `/portfolio` under MY POSITIONS

**Requirements:**
- FR-P01: System SHALL mint a Quote with a fresh per-trade subaddress when a position is requested; the Position SHALL materialise only on deposit confirmation
- FR-P02: Each YES/NO contract SHALL pay exactly 1 unit (the market's unit size) on a winning resolution
- FR-P03: Losing contracts SHALL pay 0 XMR
- FR-P04: Positions SHALL be visible in the user's Portfolio view
- FR-P05: System SHALL display the locked-in deposit amount on the Quote before the user funds it
- FR-P06: Pricing SHALL be derived from a Polymarket-style FPMM with conditional-token collateral splitting (see §7.1). `K = YES × NO` is non-decreasing across trades; integer ceiling sqrt + ceiling division on every quote so the operator's edge is the documented spread, not the curve itself.
- FR-P07: Bid/ask prices SHALL update immediately on every Quote fill
- FR-P08: Quotes SHALL expire automatically if not funded within the configured window; the AMM remains untouched until fill

### 3.5 Resolution, Disputes, and Settlement

**Resolution flow (creator-driven):**
1. Market reaches expiry — betting closes; market `:active → :expired`
2. Creator opens `/portfolio` and clicks Resolve on their market
3. Creator picks YES or NO (`:void` is **not** offered to creators — see FR-S10)
4. Market `:expired → :resolving`; the 24-hour dispute window opens
5. Anyone may file a staked dispute (see Dispute flow below)
6. If no live disputes pile up past the threshold, settle executes after the window
7. If disputes accumulate past the threshold, settle is blocked until guardian review

If the creator never submits a resolution within the deadline, the Scheduler auto-voids the market with `reason: :creator_no_show`. Open positions are refunded; no fees are collected.

**Dispute flow:**
1. User files a dispute against a `:resolving` market via `Markets.Facade.start_dispute/2`
2. System allocates a per-dispute subaddress and computes the required stake as `deposit_amount × dispute_stake_pct_bps / 10_000` (default 10% of the creator's deposit)
3. Dispute is `:awaiting_deposit` until the on-chain stake confirms; then it transitions to `:live`
4. Live dispute count past the configured threshold blocks settle
5. Guardian review options (operator-only, via Console):
   - **Acknowledge** (`acknowledge_disputes/1`) — creator's resolution stands; every live dispute → `:resolved_for` and forfeits the configured slash percentage (default 50%) to federation revenue
   - **Reverse** (`reverse_resolution/2`) — creator was wrong; market outcome flips; every live dispute → `:resolved_against` and is fully refunded
   - **Void** (`void_market/1`) — undecidable; market `:voided`, every live dispute → `:resolved_against` (full refund), positions refunded
6. Resolved disputers claim their refund via `Markets.Facade.claim_dispute_refund/3` — federation 2-of-3 signs and submits

**Settlement mechanics:**
1. Winning contracts paid 1 unit each
2. Losing contracts consumed
3. The 1.5% spread collected at trade time is split: 1.25% to the federation, 0.25% to the market creator
4. Market creation deposit returned to the creator
5. `MarketSettled` event emitted for audit trail

**Requirements:**
- FR-S01: Markets SHALL be resolved by the **market creator** via the public `/portfolio` Resolve modal. The operator backstop (`override_resolution/2`) exists in the Console for cases where the creator is unavailable.
- FR-S02: Resolution SHALL open a 24-hour dispute window during which community members can stake XMR to dispute the outcome.
- FR-S03: The operator SHALL be able to acknowledge, reverse, or void a `:resolving` market during the dispute window via the Console.
- FR-S04: After the dispute window closes with no unacknowledged live disputes past the threshold, payouts SHALL be claimable via `Cashier.claim_payout/3`.
- FR-S05: If the creator does not submit within `resolution_deadline + grace_seconds` (default 24h grace), the market SHALL be auto-voided by the Scheduler with `reason: :creator_no_show`. All open positions are refunded; no fees collected.
- FR-S06: Settlement SHALL credit winners and consume losers atomically (single compound write with CAS).
- FR-S07: System SHALL emit `ResolutionSubmitted`, `ResolutionReversed`, `DisputeFlagged`, `DisputeReReviewTriggered`, `DisputesAcknowledged`, `DisputeResolved`, `MarketSettled`, and `MarketVoided` events for audit trail. `MarketVoided` carries `reason ∈ :operator | :creator_no_show | :guardian_undecidable`.
- FR-S08: 1.5% spread SHALL be collected on every trade above the fair curve cost.
- FR-S09: On resolution, the spread SHALL be split: 1.25% to the federation, 0.25% to the market creator (configurable).
- FR-S10: Creators SHALL NOT be able to submit `:void` directly. `:void` is reserved for the operator backstop. A creator who can't resolve lets the deadline lapse — the Scheduler then auto-voids with `reason: :creator_no_show`. This closes the "void to dodge disputes" escape hatch.
- FR-S11: Disputes SHALL require an XMR stake computed as `deposit_amount × dispute_stake_pct_bps / 10_000`, where `deposit_amount` is the creator's initial escrow deposit. Default `dispute_stake_pct_bps = 1000` (10% of the creator's deposit), configurable under `[:perpwalk, :disputes, :dispute_stake_pct_bps]`. Stake is deterministic in the creator's own commitment — a 1 XMR-seeded market demands 0.1 XMR to dispute, a 100 XMR market demands 10 XMR. Volume is not a factor; sock-puppet wash-trading cannot influence the stake.
- FR-S12: Rejected disputes (`:resolved_for`) SHALL forfeit a configurable percentage of the stake to federation revenue (default 50%); the remainder is refundable to the disputer.
- FR-S13: Upheld disputes (`:resolved_against`) SHALL be fully refundable to the disputer; no slash applies.
- FR-S14: Settle SHALL refuse while the count of `:live` unacknowledged disputes is at or above the threshold (default 5).
- FR-S15: Market creators MUST NOT be permitted to file disputes against their own markets (`Disputer.start_dispute/3` returns `:creator_cannot_dispute_own_market`).
- FR-S16: A disputer MUST hold or have held a position on the market they are disputing (`Disputer.start_dispute/3` returns `:must_have_traded_on_market`). Skin in the game is the floor on dispute legitimacy.
- FR-S17: After `dispute_window_seconds` elapse from `resolution_submitted_at` with zero live disputes past the threshold, the Scheduler SHALL auto-settle the market without operator action. Sub-threshold `:live` disputes are auto-resolved as `:resolved_for` by `Resolver.settle/1` itself (so the disputer can claim the slashed refund); above-threshold disputes still block settle until guardians acknowledge or reverse.

### 3.6 Community Moderation

Markets are gated by an XMR creation deposit. Bad markets are punished by forfeiture of that deposit. The platform itself never makes content judgements.

**Flow:**
1. User creates a market — pays an XMR escrow deposit (configurable; held in the federation multisig)
2. Market enters `:pending` state with a configurable activation window
3. Community can downvote the market during the window
4. If downvotes exceed the burn threshold: market is rejected, deposit is forfeited (accrues to the federation-revenue ledger; not transferred elsewhere — the funds stay in the multisig and are sweepable via the regular payout pipeline)
5. If downvotes do not exceed threshold: market activates, deposit held until resolution
6. On successful resolution: deposit returned to creator + creator fee paid

**Requirements:**
- FR-CM01: Markets SHALL require an XMR creation deposit (configurable)
- FR-CM02: New markets SHALL enter a `:pending` state before activation; activation window is configurable
- FR-CM03: Users SHALL be able to downvote pending markets
- FR-CM04: One vote per account per market (enforced by `account_id` hash)
- FR-CM05: If the Wilson-score one-sided lower bound on the down-vote proportion exceeds the configured cutoff AND a minimum vote floor has been crossed (`Markets.Moderation.burn?/1`), the market SHALL transition to `:rejected` and the deposit SHALL be forfeited to federation revenue. The Wilson scoring is preferred over a flat threshold because it converges only when sample size is sufficient — small-N noise can't trip the burn.
- FR-CM06: A `MarketRejected` and `DepositBurned` event SHALL be emitted when a market is rejected; the funds remain in the federation multisig and are sweepable as federation revenue via the regular Federation signing pipeline
- FR-CM07: Operator SHALL NOT make content moderation decisions on `:pending` markets — only the community votes, only the protocol enforces
- FR-CM08: Operator SHALL be the **guardian** for resolution disputes (acknowledge / reverse / void) — this is a separate role from content moderation
- FR-CM09: Per-market voter cap of 10,000 distinct accounts (re-votes from an already-counted account are exempt) — bounds the DoS amplifier under Tor-circuit-rotation account-rotation spam without affecting normal moderation, which stabilises well below this cap.

### 3.7 Payouts and Withdrawals

PERP WALK has no aggregated user balance — users do not "withdraw" from the platform. Instead, every outflow is a per-claim payout:

- **Position payout** (`kind: :winner_payout` or `kind: :refund`) — winner or refunded position; user provides a destination address at claim time via `/portfolio`. `Cashier.claim_payout/3` enqueues a Payout with the Federation, which runs Rules and 2-of-3 multisig signs the transaction.
- **Dispute refund** (`kind: :dispute_refund_full` or `kind: :dispute_refund_partial`) — resolved dispute (`:resolved_for` or `:resolved_against`); same flow via `Cashier.claim_dispute_refund/3`.
- **Federation income withdrawal** (`kind: :federation_income`) — operator sweep of accumulated federation revenue (slashes + burned creator deposits + federation share of settled-market spread) to a guardian-specified address. Initiated via `Federation.Console.withdraw_federation_income/3`. Rules-gated against the live `Markets.Federation.Ledger.withdrawable_piconeros/0` so a stale console snapshot can't authorise an over-draw. Subject to an intentional ~half-of-remaining single-call cap as defense in depth — see [Federation domain Invariants](../domains/07-federation.md) and the runbook.

The destination address is provided per-claim and never persisted — minimum what-do-we-know-about-you surface.

**Requirements:**
- FR-W01: System SHALL validate Monero addresses (95-char standard, 106-char integrated, 95-char subaddress) before processing a claim
- FR-W02: Outflows SHALL be 2-of-3 federation-signed via `Federation.Signer` and `Darks.Multisig` — see [Federation domain](../domains/07-federation.md)
- FR-W03: Position payouts SHALL transition the source Position to `:paid_out` only on confirmed on-chain submission; failed submissions SHALL leave the Position in its prior payable state (`:settled_winner` or `:refunded`) so the user can retry
- FR-W04: Dispute refunds SHALL transition the source Dispute to `:refunded_full` (`:resolved_against`) or `:refunded_partial` (`:resolved_for`) only on confirmed on-chain submission
- FR-W05: System SHALL NOT persist destination addresses
- FR-W06: An idempotency guard SHALL prevent a second claim against a Position or Dispute while a non-terminal Payout already exists for it

### 3.8 Cold-Start Liquidity

PERP WALK does not run an operator-funded market-maker bot. Cold-start liquidity is solved by the creator-LP-seeded FPMM (see §7.1): the market creator's deposit IS the pool seed, the creator earns the 0.25% creator share of trade spread plus the LP residual on settlement, and the creator bears adverse-selection risk on the residual. The operator never deploys capital.

This is a deliberate trade — operator-funded MM bots are a regulatory and operational handle (capital deployment looks a lot like running a securities market), and the creator-LP model aligns incentives without giving prosecutors a market-maker entity to point at.

### 3.9 Portfolio

`/portfolio` is the user's home base — the surface where they see everything that belongs to them across the three roles they can play (creator, disputer, trader).

**Requirements:**
- FR-PF01: Users SHALL see every Position they hold across all statuses, with claim CTAs on `:settled_winner` and `:refunded` rows
- FR-PF02: Users SHALL see every Market they created with a status pill, and a "Resolve" CTA on `:expired` rows that opens a YES/NO modal calling `submit_resolution`
- FR-PF03: Users SHALL see every Dispute they filed with a status pill, stake amount, refund amount, and a "Claim refund" CTA on `:resolved_for` / `:resolved_against` rows
- FR-PF04: Empty states SHALL render the standard "NO X YET" message rather than hiding the panel
- FR-PF05: The Resolve modal SHALL offer YES and NO only; `:void` SHALL NOT be exposed to creators (FR-S10)

### 3.9.1 Market Detail Comments

Every market's `/markets/:id` page carries an anonymous comment surface backed by Nostr (kind:1 events tagged with the NIP-33 `a` reference to the market). The audit trail itself still exists in the WAL and Markets store — the trades feed UI was dropped because anonymous discourse is the higher-signal surface for a privacy-native audience.

**Flow:**
1. Viewer arrives at `/markets/:id`; comments are loaded from `Markets.Comments.Inbox.list_for_market/1` and rendered newest-first.
2. Logged-in viewer types a comment in the composer; client submits via `phx-submit="comment:submit"`.
3. LiveView looks up the viewer's per-venue Nostr seckey via `Identity.Sessions.lookup_nostr_seckey/1` and calls `Markets.Comments.Composer.publish/4` with `(seckey, venue_pubkey_hex, market_id, content)`.
4. `Markets.Comments.Composer.publish/4` builds a signed kind:1 event with two tags — `["t", "perpwalk-market-comment"]` and `["a", "30819:<venue_pubkey>:<market_id>"]` — direct-injects into the Inbox for instant local visibility, then fans out to every configured relay (Tor-tunneled).
5. The viewer's comment appears immediately (local ingest); other viewers see it via the inbound Subscriber pool → `CommentReceived` event → live LiveView update.

**Requirements:**
- FR-CT01: Each market detail page SHALL render a composer for logged-in users and a "Log in to post" notice for anonymous viewers.
- FR-CT02: Comments SHALL be signed kind:1 Nostr events under the author's per-venue derived Nostr key; the venue MUST NOT accept "bring your own npub" as an alternate identity.
- FR-CT03: Comment content SHALL be trimmed of whitespace and capped at 5000 bytes (`@max_content_bytes` in `Markets.Comments.Composer`).
- FR-CT04: Inbound comments from other relays SHALL be Schnorr-verified by `Nostr.Event.verify/1` and routed through `Comments.Inbox.ingest/1` for dedup before any LiveView consumer sees them. The inbox enforces a `@primary_cap 100_000` global cap (past it `ingest/1` returns `:inbox_full`) and refuses comments tagged at unknown market_ids in production (`:unknown_market`; configurable via `[:perpwalk, :inbox, :require_market_existence]`).
- FR-CT05: The Inbox SHALL cap per-market entries at `@per_market_cap 500`, apply a `@max_age_ms` 14-day TTL, and sweep hourly (`@sweep_interval_ms 60 * 60 * 1_000`).

> **NOT YET IMPLEMENTED**: A `pos-attest` cryptographic badge (venue Schnorr signature over `(author_pubkey, market_id, expires_at)`) attesting that a commenter holds an open position on the market. `Markets.Comments.Composer.build/4` currently emits only the two tags above — no attestation tag. The badge is a design aspiration for a future release; when implemented, requirements will be recorded here as FR-CT06+ and the composer will grow a position-holder pathway.

### 3.9.2 Calibration Leaderboard

The `/` home and `/markets` browse share a 2/3 markets table + 1/3 leaderboard layout. The leaderboard ranks accounts by prediction accuracy across resolved markets.

**Requirements:**
- FR-LB01: The leaderboard SHALL rank accounts by `wins / total` win-rate descending, with `total` as tiebreaker (more resolved markets ⇒ more confidence ⇒ higher rank when win-rate ties).
- FR-LB02: Accounts below the configured `min_resolved` threshold MUST NOT appear (default 10; launch-bootstrap value lower until volume crosses the cap).
- FR-LB03: `:voided` markets MUST be excluded from both the win numerator and the total denominator — they represent no prediction outcome.
- FR-LB04: The leaderboard surface MUST NOT display piconero values, per-market positions, position sides, or any identifier beyond the derived friendly handle. Doxxing surface is the deliberate concern.
- FR-LB05: The leaderboard SHALL refresh on `MarketSettled` and `MarketVoided` events so a freshly resolved market updates rankings without a page reload.

### 3.10 Admin Dashboard

Served on a separate port bound to a dedicated Tor hidden service. The `.onion` address itself is the capability — no additional auth. The dashboard is **read-only** by design — every state-changing operation (resolve, reverse, settle, void, force-sign, halt) goes through `iex --remsh`, never the dashboard. This keeps the admin surface a status surface, not a work surface.

**Requirements:**
- FR-A01: Dashboard SHALL display Markets stats (active, pending, resolving, total)
- FR-A02: Dashboard SHALL display Activity (24h volume, trades) and Pool TVL
- FR-A03: Dashboard SHALL display the **House Income** panel with six rows: Total earned, Slashes, Burns, Spread (federation share of settled-market spread), Drawn (cumulative federation income withdrawals submitted), and Available (Total − Drawn, highlighted as the actionable number for the operator). The panel SHALL refresh on `PayoutRequested`, `PayoutSubmitted`, `PayoutFailed`, `DisputeResolved`, `DepositBurned`, and `MarketSettled` events so withdrawals update live.
- FR-A04: Dashboard SHALL display System metrics (CPU, memory) as sparklines
- FR-A05: Dashboard SHALL display Active Alerts and a live Event Stream of recent domain events
- FR-A06: Dashboard SHALL be served only on the admin `.onion` (enforced by `OnionOnly` plug)
- FR-A07: Dashboard SHALL follow Blueprint design language
- FR-A08: Dashboard SHALL NOT expose any write endpoints — operator state changes go through `iex --remsh` console tools

---

## 4. Non-Functional Requirements

### 4.1 Privacy

- NFR-P01: System SHALL NOT store or log user IP addresses
- NFR-P02: System SHALL NOT require email, name, or any identifying information
- NFR-P03: All user-facing services SHALL be accessible only via Tor hidden services
- NFR-P04: Zero clearnet exposure — no DNS records, no public IP, no CDN
- NFR-P05: Access codes SHALL be hashed; raw codes never stored
- NFR-P06: XMR deposit subaddresses SHALL be unlinkable to each other and to the primary wallet
- NFR-P07: No analytics, no tracking pixels, no third-party scripts
- NFR-P08: Wallet view key MAY be published for reserve transparency. The Reserves domain SHALL publish signed proof-of-reserves attestations on a fixed cadence to (a) the `/api/reserves` HTTP endpoint, (b) NIP-33 replaceable Nostr events, and (c) implicitly via the on-chain multisig wallet itself

### 4.2 Security

- NFR-S01: Wallet keys SHALL be encrypted at rest (AES-256-GCM, PBKDF2-derived) via `Cartel.KeyStore` per guardian
- NFR-S02: Backups SHALL be encrypted and integrity-verified (HMAC-SHA256)
- NFR-S03: Admin surface SHALL be reachable only via dedicated Tor hidden service
- NFR-S04: All outbound HTTP SHALL go through the Tor HTTP tunnel — no clearnet leaks
- NFR-S05: Every Monero outflow SHALL be signed by 2 of 3 guardians — single-guardian compromise MUST NOT enable spending
- NFR-S06: Each guardian SHALL hold a unique signing passphrase — compromise of one guardian MUST NOT yield another's signing key
- NFR-S07: The federation SHALL detect quorum loss within 30s via `Cartel.Health.HealthMonitor` and pause auto-signing until quorum returns
- NFR-S08: PayoutRequests rejected by the rules engine MUST NOT be auto-signed under any circumstance — operator override SHALL be explicit via `Federation.Console.force_sign/1`

### 4.3 Availability

- NFR-A01: System SHALL implement automatic crash recovery (WAL replay, DETS-backed cold tiers)
- NFR-A02: System SHALL perform automatic backups with HMAC integrity verification
- NFR-A03: System SHALL expose health endpoints: `/health/live`, `/health/ready`
- NFR-A04: System SHALL implement 4-state health model: healthy → degraded → critical → halted
- NFR-A05: System SHALL alert operator via Nostr DMs on critical conditions
- NFR-A06: System SHALL auto-halt on critical conditions: state divergence, disk > 95%, monerod unreachable for >5min

---

## 5. Architecture

### 5.1 Technology Stack

| Layer | Technology | Purpose |
|-------|------------|---------|
| **Application** | Elixir / OTP 27 | Market logic, user management, AMM, supervision |
| **Web** | Phoenix / LiveView | Markets UI, portfolio, admin dashboard |
| **Custody** | Per-trade subaddresses + 2-of-3 multisig | No aggregated balances; every XMR movement gets its own subaddress; outflows are federated |
| **Monero** | `darks` (Darks.Client + Darks.Multisig) | Wallet RPC for inflows; native Monero multisig protocol for outflows |
| **Network** | Tor hidden services | Anonymous user access |
| **Storage** | ETS + DETS + WAL | In-memory state, persistent cold-tier records, write-ahead log |
| **Monitoring** | Telemetry + LiveView + Nostr DMs | Alert rules, health model, event-driven dashboard |
| **Design system** | Blueprint | Shared UI language across all products |

### 5.2 Federated Architecture

PERP WALK runs as a **2-of-3 Cartel federation** with `Darks.Multisig` for the Monero signing protocol. Three independent nodes — different operator aliases, different hosts, different jurisdictions. Each holds one of three Monero multisig key shares. Every outflow requires two-node co-signature; single-node compromise cannot move funds.

- **All three nodes are equal.** Identical code, identical config, identical secrets. There is no storage leader or follower; every node accepts local writes and replicates bidirectionally to its peers via `Storage.Replicator`. Any 2 of 3 can complete a multisig signing round.
- **External routing decides which guardian serves the public onion.** The public `.onion` HiddenService key currently lives on one guardian; OnionBalance fanning the descriptor across all three guardians is a planned post-launch improvement. The app itself doesn't know or care which guardian is fronting.
- **Failover is manual.** If the front-facing guardian dies, the operator moves the HiddenService keypair to a surviving peer and re-publishes the descriptor.
- BEAM supervision tree per node handles per-node crash recovery; Cartel handles peer-mesh formation, encrypted key share storage, signed transport, and quorum tracking.
- WAL + ETS handles durable state. `Storage.Replicator` ticks every second on every node and pulls entries past per-peer cursors from each peer via `:rpc.call`, then dispatches via `Markets.Facade.replicate_entries/1`, `Federation.Facade.replicate_entries/1`, and the other per-domain replication entry points. Three nodes → three live WAL copies, each lagging the others by at most one tick.
- Wallet keys are persisted by `Cartel.KeyStore` (AES-256-GCM at rest, PBKDF2-derived from per-node passphrase). Each node has a unique passphrase — compromise of one node cannot derive another's keys.
- See [Federation domain doc](../domains/07-federation.md) for the threat model, bootstrap ceremony, failure modes, and recovery flows.

### 5.3 Sovereign Signpost

The sovereign signpost is a static clearnet page hosted on a protected-speech-friendly registrar that points at the Tor onion. It carries no operational surface — no wallet, no API, no user state — and is never CDN-proxied. Its job is to serve the speech-defense framing and the current onion address.

The venue itself is `.onion`-only. There is no operational clearnet surface.

---

## 6. Fee Structure

| Operation | Fee | Notes |
|-----------|-----|-------|
| Deposit | Free | Encourage inflows |
| Position | 1.5% spread | Collected on top of the fair curve cost of every trade. |
| Settlement | 0% | Settlement itself is free; revenue already collected as spread |
| Payout | XMR network fee | Federation transaction fee passed through to user |
| Market creation | XMR escrow | Returned on successful resolution. Forfeited to federation revenue if market is community-rejected. |
| Dispute | XMR stake | `deposit_amount × dispute_stake_pct_bps / 10_000` (default 10% of the creator's deposit). 50% slash on rejection (`:dispute_slash_pct`, configurable); 100% refund on upheld dispute. |

**Spread split (paid from the 1.5% collected on every trade):**

| Recipient | Share | Notes |
|-----------|-------|-------|
| Federation | 1.25% | Federation revenue |
| Creator | 0.25% | Paid to market creator on successful resolution. Voided markets pay no creator fee. |

**Federation-revenue sources (in addition to spread):**

| Source | Trigger | Rate |
|--------|---------|------|
| Slashed dispute stakes | Disputes ruled `:resolved_for` (creator stood) | Configurable slash percentage of stake (default 50%) |
| Forfeited creator deposits | Markets community-rejected during `:pending` | 100% of the deposit |

The federation-revenue ledger is derived read-only from existing Store data (`Markets.Facade.federation_ledger/0`) — no separate persistence. Funds remain in the federation multisig and can only be moved through the standard 2-of-3 signing pipeline.

---

## 7. Market Mechanics

### 7.1 Constant-Product AMM

Each market is backed by a **Polymarket-style FPMM** (Fixed Product Market Maker) with conditional-token collateral splitting. Same product invariant `K = YES × NO` defines the pricing curve, but a buy is modelled as a 1:1 collateral split: the user deposits `c` collateral, which mints `c YES + c NO` via the conditional-tokens framework. The pool absorbs the entire opposite-side tokens, growing that reserve by `c`. The bought-side reserve adjusts to maintain `K`, ending at `(bought + c − dY, other + c)`. The user keeps `dY` contracts.

This collateral-splitting structure is what makes FPMM pricing match marginal probability for small trades. A plain "user-takes-contracts-out-of-pool" constant product (without splitting) overcharges by a constant factor at every trade size — the operator's edge becomes the curve itself rather than the documented spread.

**Initial state (creator seeds the pool):**
```
YES pool:  (deposit_amount / unit_size) × pool_scale contracts
NO pool:   (deposit_amount / unit_size) × pool_scale contracts
Invariant: K_new ≥ K_old after every trade
```

Pool reserves are the AMM-curve representation of the creator's deposited LP collateral. PERP WALK is an LP-seeded FPMM: the market creator's deposit IS the pool seed, the operator never deploys capital, and the creator earns the 0.25% creator share of trade spread + an LP residual on settlement (`pool.<winning_side> × unit_size`) in exchange for bearing adverse-selection risk on the residual. See `Markets.Services.Maker.create_market/1` and the per-market `pool_scale` config.

**Implied probability:**
```
P(YES) marginal = NO_pool / (YES_pool + NO_pool)
```

At start: 1000 / 2000 = 50% probability for YES.

**On a buy:** solving for `c` given a target `dY` yields the quadratic

```
c² + c(bought + other − dY) − dY × other = 0
c = (−(bought + other − dY) + √((bought + other − dY)² + 4·dY·other)) / 2
```

solved in integer math with ceiling sqrt + ceiling division so any fractional remainder favours the house. `K` is **non-decreasing** across trades — never collapses below the initial product.

**Concrete pricing under FPMM:**

| Trade | Cost (in contract units) | Effective per-contract price |
|---|---|---|
| 1 YES from (100, 100) | 2 (1 AMM + 1 spread) | 2.00 |
| 100 YES from (1000, 1000) | 53 (52 AMM + 1 spread) | 0.53 |

**Pricing (marginal):**
```
mid_price = NO_pool / (YES_pool + NO_pool)
trade_cost = fair_curve_cost × 1.015   (1.5% spread on top)
```

The 1.5% spread is charged on top of the fair FPMM curve cost of every trade. Fair curve cost is what an unfeed pool would charge; the AMM adds 1.5% and routes 1.25% to the federation ledger and 0.25% to the creator at settlement.

**Pool depth tuning:**
Initial pool size controls price sensitivity:
- Deep pool (1000+ contracts each side) → stable odds, large trades barely move price
- Shallow pool (100 contracts each side) → volatile odds, trades move price quickly

Pool depth is configurable per market — set by operator at creation based on expected volume.

### 7.2 Cold-Start Liquidity

PERP WALK does not run an operator-funded market-maker bot — see §3.8 for the rationale. The creator-LP-seeded FPMM solves the cold-start liquidity problem economically by aligning incentives between the creator (LP residual + spread share) and the platform (no capital deployment, no MM-entity regulatory handle).

### 7.3 Market Lifecycle

```
:awaiting_deposit  Created via Maker; subaddress allocated; awaiting on-chain deposit
       |
:pending           Deposit confirmed; community vote window open
       |
:active            Survived the vote window; accepting positions; prices moving via AMM
       |
:expired           Expiry reached; no new positions; awaiting creator resolution
       |
:resolving         Creator (or operator) submitted YES/NO; dispute window open
       |
:settled           Outcome confirmed, winners paid, losers consumed, atomic

Side branches:
  :pending  →  :rejected   (community downvoted; deposit forfeited to federation revenue)
  :expired  →  :voided     (creator missed deadline; auto-void with reason: :creator_no_show)
  :resolving →  :voided     (guardian declared undecidable; reason: :guardian_undecidable)
                            OR operator-initiated; reason: :operator
  :resolving →  :resolving  (operator reversed; outcome flipped; live disputes auto-resolved)
```

### 7.4 Voided Markets

A market is voided in any of three scenarios, each tagged on the `MarketVoided` event:

- `:creator_no_show` — Scheduler auto-voids past `resolution_deadline + grace`. Creator never submitted a resolution. All open positions refunded; any pending live disputes auto-resolve as `:resolved_against` (full refund, no slash). No fees collected.
- `:guardian_undecidable` — Scheduler auto-voids a `:resolving` market past `resolution_deadline + grace`. Guardians never acknowledged disputes within the deadline. Same refund treatment as above.
- `:operator` — Explicit operator-initiated void via `Markets.Console` (e.g. genuinely undecidable question, fraudulent market that slipped past pending). Same refund treatment.

Disputers on a voided market always get full refunds, regardless of the void reason. Voiding is the "everyone gets their money back" terminal state — it never accrues anything to federation revenue beyond what was already in the ledger from prior `:rejected` markets or `:resolved_for` disputes.

---

## 8. Categories

Markets must belong to one category at creation time. Categories are fixed (not user-configurable):

- **Politics** — elections, legislation, geopolitical events
- **Crypto** — protocol upgrades, listings/delistings, milestone prices, forks
- **Finance** — rate decisions, recession calls, market events, earnings
- **Sports** — match outcomes, championships, transfers, records
- **Entertainment** — awards, releases, finales, viral moments
- **Science/Tech** — launch dates, AI milestones, FDA approvals, releases
- **Culture** — celebrity events, social trends, internet culture
