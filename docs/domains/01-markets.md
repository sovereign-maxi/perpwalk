# PERP WALK — Markets Domain

The core of PERP WALK. Owns the entire market lifecycle: creation, moderation, AMM pricing, positions, resolution, disputes, settlement, and the federation-revenue ledger.

---

## Purpose

The Markets domain implements binary outcome prediction markets on a Polymarket-style FPMM (Fixed Product Market Maker) with conditional-token collateral splitting. It owns every entity that lives or dies inside a market: the market itself, its positions, its quotes, its votes, its disputes, the federation-revenue ledger, the comment substrate, and the calibration leaderboard.

This includes:

- Market creation, with a creator-paid escrow deposit and a community-vote rejection path that burns the deposit
- FPMM pricing with a 1.5% spread collected on every trade — 1.25% to federation, 0.25% to creator
- Per-trade Monero subaddress allocation via the Quote pattern (no idle user balances)
- Position-taking against the AMM curve once a deposit confirms
- Creator-driven resolution constrained to YES/NO, with operator-only `:void` access
- Community disputes with a volume-scaled XMR stake, partial slashing on rejection, and full refund on guardian reversal
- Atomic settlement of winners/losers, refund flows for voided markets and resolved disputes
- A federation-revenue ledger (slashes + forfeited deposits + federation share of settled-market spread) surfaced on the admin panel
- Anonymous Nostr-distributed comments on every market
- A calibration leaderboard ranking accounts by win rate over resolved markets
- Nostr publication of every market lifecycle transition (NIP-33 kind 30819) so external clients can mirror the venue without a direct relay subscription

Everything that happens *to* a market — every bet, every downvote, every resolution decision, every dispute, every payout claim — lives inside this domain.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Market** | A binary YES/NO question with an expiry, a resolution deadline, an AMM pool, and a category |
| **Unit size** | The base contract size for a market (configurable per market) |
| **Contract** | A single YES or NO unit. Wins pay 1 unit, losses pay 0 |
| **Pool** | YES and NO contract reserves that define the FPMM pricing curve. `K = YES × NO` is non-decreasing across trades (operator-favouring ceiling rounding). The creator's deposit seeds the pool as real LP collateral (LP-seeded FPMM); the operator never deploys capital. Pool reserves are the AMM-curve representation of that collateral |
| **Creator LP return** | Residual XMR returned to the creator on `:settled` (`pool.<winning_side> × unit_size`) or full deposit returned on `:voided`. Paid via `Cashier.claim_creator_lp_return/3` once the market reaches its terminal state; `creator_lp_paid_out_at` is stamped post-Signer-submit and drops the market from the Reserves liability total |
| **FPMM** | Fixed Product Market Maker (Polymarket-style). A buy splits user collateral 1:1 into YES + NO via conditional-tokens semantics; pool absorbs the opposite-side tokens. Cost is the solution to `c² + c(bought + other − dY) − dY × other = 0` computed in integer math with ceiling sqrt + ceiling division |
| **Spread** | The 1.5% the AMM collects on top of the fair curve cost of every trade |
| **Position** | A user's holding of N contracts on one side of one market |
| **Quote** | A pending position with a fresh per-trade Monero subaddress; materialises into a Position when the deposit confirms |
| **Creation deposit** | XMR escrow paid by the market creator at creation time, held in the federation multisig until resolution |
| **Burn** | Forfeiture of a creator's deposit on community-rejection. The funds remain in the multisig wallet and accrue to the federation as platform revenue — "burn" is the legacy event-name, not actual destruction |
| **Downvote** | A community signal against a `:pending` market; one per account per market |
| **Reputation** | A market's score derived from net votes |
| **Resolution** | The market's terminal outcome (`:yes`, `:no`, or `:void`) |
| **Dispute** | A staked, on-chain XMR commitment that the creator's resolution is wrong |
| **Stake** | The XMR a disputer locks up to file a dispute. Deposit-scaled: `deposit_amount × dispute_stake_pct_bps / 10_000` with `dispute_stake_pct_bps` defaulting to 1000 (10% of the creator's deposit). A 1 XMR seeded market demands 0.1 XMR to dispute; a 10 XMR market demands 1 XMR. Volume is not a factor — sock-puppet wash-trading cannot influence the stake |
| **Slash** | Forfeiture of a configurable percentage of a disputer's stake on rejection (default 50%) |
| **Live dispute** | A dispute whose deposit has confirmed; only live disputes count toward the re-review threshold |
| **Re-review threshold** | Minimum number of live unacknowledged disputes that block settlement until guardians act |
| **Acknowledge / Reverse** | Guardian outcomes on a `:resolving` market — acknowledge confirms creator's resolution, reverse flips it |
| **Auto-void reason** | Tag on `MarketVoided` distinguishing operator-initiated, creator-no-show, and guardian-undecidable voids |
| **Federation revenue** | Cumulative platform revenue, derived from three sources: slashed dispute stakes, forfeited creator deposits, and the 1.25% federation share of the AMM spread captured at trade time on settled markets. Held in the federation multisig; movable only via the standard 2-of-3 signing pipeline |
| **Trade spread** | The 1.5% the AMM collects on top of every trade cost. Captured at trade time and split at settlement: 1.25% to federation, 0.25% to creator |
| **Federation income withdrawal** | Operator-initiated payout that sweeps accumulated federation revenue to a guardian-specified address; rules-gated against the live `Markets.Federation.Ledger.withdrawable_piconeros/0` so a stale console snapshot can't over-draw |

## Aggregates

**Market** (aggregate root)
- Status state machine: `:awaiting_deposit → :pending → :active → :expired → :resolving → :settled`
- Side branches: `:pending → :rejected` (downvoted, deposit forfeited), `:expired | :resolving → :voided` (operator/scheduler)
- Carries the AMM pool inline, the creation deposit subaddress, and the disputes-acknowledged watermark

**Position** — entity inside a market
- `account_id`, side (`:yes`/`:no`), contracts, amount_paid, status (`:open` / `:settled_winner` / `:settled_loser` / `:refunded` / `:paid_out`)
- Transitions are atomic with the market's settle/void compound write via a CAS guard

**Quote** — pending position
- `account_id`, market_id, side, contracts, amount expected, deposit subaddress + index, expiry
- Consumed into a Position by `Trader.fill_quote/2` when `Monero.Poller` confirms the deposit
- Expires automatically via the Scheduler if no deposit lands in the window

**Vote** — entity inside a market
- account_id, market_id, direction (`:up`/`:down`), created_at
- One per account per market; re-puts overwrite

**Dispute** — entity inside a market
- account_id, market_id, status (`:awaiting_deposit | :live | :resolved_for | :resolved_against | :refunded_full | :refunded_partial`), stake_amount_piconeros, deposit_subaddress + index, slashed_amount_piconeros
- Keyed by `{account_id, market_id}` — one dispute per account per market
- Filing restrictions: a creator MUST NOT dispute their own market (`Disputer.start_dispute/3` returns `:creator_cannot_dispute_own_market`); a disputer MUST hold or have held a position on the market they are disputing (`:must_have_traded_on_market`)
- Transitions: `:awaiting_deposit → :live` on deposit confirmation; `:live → :resolved_for` (creator confirmed, partial slash) or `:resolved_against` (guardians reversed, full refund); `:resolved_* → :refunded_*` once federation submits the refund payout
- Sub-threshold `:live` disputes are auto-resolved as `:resolved_for` by `Resolver.settle/1` itself (so the disputer can claim the slashed refund); only disputes whose live count crosses the re-review threshold block settle until guardians acknowledge or reverse

**AMM** (value object)
- Pure functions over Market state: FPMM pricing, slippage, post-trade pool calculation
- Cost = `ceil_div(isqrt_ceil(b² + 4·contracts·other) − b, 2)` where `b = bought + other − contracts`; new_bought = `bought + cost − contracts`, new_other = `other + cost`. K is non-decreasing
- No external state, no IO

**Moderation** — pure logic
- Vote tallies, Wilson-score one-sided lower-bound reputation calculation (default lower bound 0.6, z = 1.96 ≈ 95% confidence), downvote-burn threshold check
- Per-market hard ceiling of `@max_votes_per_market 10_000` distinct voters (enforced in `Voter`; re-votes from an already-counted account are exempt) — bounds the DoS amplifier under account-rotation spam without affecting normal moderation
- Dispute stake derivation: `deposit_amount × dispute_stake_pct_bps / 10_000`. Config key `:dispute_stake_pct_bps` in `[:perpwalk, :disputes, ...]` defaults to 1000 (10%). Deterministic in the creator's own commitment; wash-trading cannot influence the stake.
- Slash percentage configurable via `:perpwalk, :disputes, :dispute_slash_pct` (default 50)

**Federation.Ledger** — counter-backed ledger
- `breakdown/0` reads incremental ETS counters in O(1). Counters are maintained at write time by the `insert_*` helpers in `Markets.Store`:
  - **Slashed disputes** — incremented when a dispute transitions into `:resolved_for` with a positive slash amount
  - **Burned creator deposits** — incremented when a market transitions into `:rejected`
  - **Trade spread** — incremented when a market transitions into `:settled`, summing each Position's `spread_piconeros`
- `reconcile/0` cross-checks the counter values against a fresh index-walk derivation — useful after restart and as a periodic integrity probe. Returns `:ok` on agreement or `{:error, [mismatch()]}`.
- Federation share is 1.25% of the trade cost; creator share is 0.25%, included in the creator LP-return payout via `Cashier.claim_creator_lp_return/3` once the market settles. Floor-division remainder of a few piconeros per settled market stays in the wallet, marginally above the counter sums — by design.
- `withdrawable_piconeros/0` returns `max(0, total_earned − federation_income_drawn)` so federation withdrawal can be sized correctly without the operator having to compute it. WAL replay funnels through the same `insert_*` helpers as live writes, so the counters rebuild at boot.

**Categories** (value object)
- Fixed list: politics, crypto, finance, sports, entertainment, science_tech, culture

**Services**
- `Maker` — market creation flow (deposit subaddress allocation, deposit confirmation)
- `Voter` — vote casting and downvote-burn evaluation
- `Trader` — quote creation, fill on deposit confirmation, position state
- `Resolver` — submit/reverse/acknowledge/settle/void
- `Disputer` — start dispute, confirm deposit, threshold-trigger publication
- `Cashier` — claim payout for a position, claim refund for a resolved dispute, mark-paid-out / mark-refunded callbacks invoked by `Federation.Signer`

**Comments** — anonymous discourse on every market

- `Comments.Inbox` — GenServer + ETS table (`@table` primary keyed by event_id, `@by_market_table` secondary keyed by market_id). Receives verified Nostr comment events via `ingest/1`, dedups by event_id (multiple relays echo the same event), indexes by market_id for O(1) LiveView reads. Per-market cap of 500, global primary cap of `@primary_cap 100_000` (overflowing ingests return `:inbox_full`), 14-day TTL, hourly sweep. Production refuses to ingest a comment whose `market_id` doesn't resolve in the local Store (`:unknown_market`); the existence check is configurable via `:perpwalk, :inbox, :require_market_existence` so unit tests can opt out with synthetic ids. Emits `MarketsEvents.CommentReceived` on every *new* (post-dedup) ingest so subscribed LiveViews live-append without re-fetching.
- `Comments.Composer` — pure event builder + dispatcher. `build/4` constructs a kind:1 Nostr event with `["t", "perpwalk-market-comment"]` topic tag and `["a", "30819:<venue_pubkey>:<market_id>"]` NIP-33 addressable reference; signs with the author's per-venue seckey (looked up at submit time from `Identity.Sessions.lookup_nostr_seckey/1`). `publish/4` direct-injects into the Inbox first (instant visibility for the author) then fans out to every configured relay via `Nostr.Facade.publish_event/2`. Content cap: 5000 bytes after trim.

**Publishers.Nostr** — market lifecycle distribution

- GenServer started as a Markets supervisor child. Subscribes to eight market lifecycle events: `MarketDepositConfirmed`, `MarketActivated`, `MarketRejected`, `MarketExpired`, `ResolutionSubmitted`, `ResolutionReversed`, `MarketSettled`, `MarketVoided`. On each event, fetches the current `Market.t()` from `Store`, builds an NIP-33 replaceable Nostr event (kind 30819), signs with the venue Nostr key (same encrypted key file `Reserves.Publishers.Nostr` uses), and dispatches to every configured relay through `Nostr.Relay.Client` (Tor-tunneled).
- NIP-33 semantics make publication self-superseding: the tuple `(pubkey, kind=30819, d=market_id)` identifies the event, so each lifecycle transition replaces the previous state for that market across the relay set. No "delete" needed.
- Tags carried: `["d", market_id]`, `["t", "perpwalk-market"]`, `["status", atom_as_string]`, `["category", atom_as_string]`, `["expiry", iso8601]`, `["resolution_deadline", iso8601]`, `["outcome", atom_as_string]` (only after resolution).
- Lazy key load avoids racing the application supervisor at boot (Markets boots before Reserves; the publisher loads the venue key on its first publish, which by then has been written by Reserves' load-or-generate path).

**Leaderboard** — calibration ranking

- Pure module. `compute/1` walks every `:settled` market with binary outcome (`:yes` or `:no`), aggregates per-account `(wins, total, last_active_at)` by comparing `position.side` against `market.outcome`. Voided markets are excluded from both numerator and denominator.
- Filters by `:min_resolved` (default 10; relaxed to 3 in the launch LiveView for low-volume warmup), sorts by win-rate descending with `markets_resolved` as tiebreaker (more resolved = more confidence in the percentage) and `account_id` as final deterministic tiebreaker. Takes `:limit` entries.
- Privacy surface: ranking deliberately omits piconero values, per-market positions, and any off-handle identifier. Only displays rank, derived handle (via `Identity.Account.handle_for/1`), `wins/total`, and integer win percentage. The high-leverage doxx vector here is conscious.

## Commands

| Command | Path | Description |
|---------|------|-------------|
| Create market | `Facade.create_market/1` | Allocate deposit subaddress, persist `:awaiting_deposit` market |
| Confirm market deposit | `Facade.confirm_market_deposit/1` | Called by `Monero.Poller`; transitions `:awaiting_deposit → :pending` |
| Vote | `Facade.cast_vote/3` | Up or down vote; downvotes can trigger rejection + burn |
| Activate market | `Facade.activate_market/1` | Transitions `:pending → :active` after the pending window |
| Expire market | `Facade.expire_market/1` | Transitions `:active → :expired` once the expiry timestamp passes |
| Create quote | `Facade.create_quote/4-5` | Mints a Quote with a fresh per-trade subaddress |
| Fill quote | `Facade.fill_quote/1-2` | Called by `Monero.Poller`; consumes the Quote into a Position |
| Submit resolution | `Facade.submit_resolution/3` | Creator-driven, **YES/NO only**; auth-checked |
| Override resolution | `Facade.override_resolution/2` | Operator-only; bypasses creator check; allows `:void` |
| Reverse resolution | `Facade.reverse_resolution/2` | Operator-only; flips outcome inside dispute window; auto-resolves live disputes as `:resolved_against` |
| Start dispute | `Facade.start_dispute/2` | Allocates a per-dispute subaddress, persists `:awaiting_deposit` |
| Confirm dispute deposit | `Facade.confirm_dispute_deposit/2` | Called by `Monero.Poller`; transitions `:awaiting_deposit → :live` |
| Acknowledge disputes | `Facade.acknowledge_disputes/1` | Operator-only; auto-resolves live disputes as `:resolved_for` (slash applies) |
| Settle market | `Facade.settle_market/1` | Refuses if live disputes are unacknowledged; pays winners, consumes losers, atomic |
| Void market | `Facade.void_market/1` | Operator-only; refunds every open position, resolves any live disputes as `:resolved_against` |
| Claim payout | `Facade.claim_payout/3` | For `:settled_winner` / `:refunded` positions; enqueues Payout with Federation |
| Claim dispute refund | `Facade.claim_dispute_refund/3` | For `:resolved_for` (partial) / `:resolved_against` (full) disputes; enqueues Payout |
| Mark position paid out | `Facade.mark_position_paid_out/2` | Called by `Federation.Signer` after on-chain submission |
| Mark dispute refunded | `Facade.mark_dispute_refunded/2` | Called by `Federation.Signer` after on-chain submission |
| Claim creator LP return | `Facade.claim_creator_lp_return/3` | Creator collects pool residual on `:settled` or full deposit on `:voided` (enqueues a `:creator_lp_return` Payout) |
| Mark creator LP returned | `Facade.mark_creator_lp_returned/2` | Called by `Federation.Signer` after on-chain submission; stamps `creator_lp_paid_out_at` and drops the market from the Reserves liability total |
| Federation-revenue breakdown | `Facade.federation_ledger/0` | Read-only ledger: total / slashed / burned piconeros + counts |

## Resolution and Dispute Flow

```
Market expires
   │
   ▼
Creator submits :yes or :no  ──── (creator can NOT submit :void)
   │                              if creator never resolves: Scheduler
   ▼                              auto-voids with reason: :creator_no_show
:resolving (dispute window opens)
   │
   ├── User files dispute  ──► Dispute :awaiting_deposit (subaddress allocated)
   │     │
   │     ▼ deposit confirms
   │   Dispute :live (counts toward re-review threshold)
   │     │
   │     │  When live count crosses threshold AND is past
   │     │  the disputes-acknowledged watermark for the
   │     │  first time, DisputeReReviewTriggered fires.
   │     │  Settle is blocked until guardians act.
   │
   ▼
Guardian review
   │
   ├── acknowledge_disputes/1 (creator was right)
   │     ├── All live disputes → :resolved_for (slash applies)
   │     └── disputes_acknowledged_count += live_count
   │
   ├── reverse_resolution/2 (creator was wrong)
   │     ├── Market.outcome flipped, status stays :resolving
   │     └── All live disputes → :resolved_against (full refund)
   │
   └── void/1 from :resolving (operator-only)
         ├── Market → :voided
         └── All live disputes → :resolved_against (full refund)
   │
   ▼
:settled (settle_market) OR :voided (void)
   │
Disputers claim refunds via Cashier.claim_dispute_refund/3 →
   Federation.Facade.enqueue_dispute_refund → 2-of-3 sign → :refunded_full / :refunded_partial
```

The watermark mechanic prevents a settle-after-ack flood: every fresh dispute filed *after* guardians acknowledge the current set re-arms the threshold. `Resolver.ensure_disputes_reviewed/1` checks the live count directly, so an honest reviewed batch passes immediately while a fresh attack is caught.

## Boundaries

**Owns**: Market state machine, AMM pricing, positions, votes, reputation, resolution lifecycle, dispute lifecycle, settlement orchestration, creation-deposit lifecycle, dispute-stake derivation, slash configuration, federation-revenue derivation

**Depends on**:
- `Storage.Facade` — `markets_dir/0` for the data directory; the Markets-owned WAL writes go through `Locker.WAL.append` directly from `Markets.Store` per the WAL-facade exemption
- `Monero.Facade.create_subaddress/0` — per-trade and per-dispute subaddress allocation
- `Federation.Facade.enqueue_payout/3` — winner / position-refund flows
- `Federation.Facade.enqueue_dispute_refund/3` — dispute-refund flows
- `Identity.Facade` — only for handle derivation in views

**Does not own**:
- XMR custody (Federation owns the multisig wallet; Monero owns the RPC)
- User identity (Identity domain)
- Payout state machine (Federation owns it; Markets only knows about position / dispute terminal states)

## Published Language (Markets.Facade)

External callers interact with Markets exclusively through `PerpWalk.Markets.Facade`. Public surface covers:

- **Market lifecycle**: `create_market/1`, `confirm_market_deposit/1`, `cast_vote/3`, `activate_market/1`, `expire_market/1`, `submit_resolution/3` (creator), `override_resolution/2` (operator), `reverse_resolution/2`, `acknowledge_disputes/1`, `settle_market/1`, `void_market/1`
- **Quotes & Positions**: `create_quote/4-5`, `fill_quote/1-2`, `get_quote/1`, `list_quotes/0`, `list_quotes_for_market/1`, `list_quotes_for_account/1`, `get_position/1`, `list_positions_for_market/1`, `list_all_positions/0`, `list_positions_for_account/1`, `list_positions_by_status/1`, `quote_expired?/2`
- **Disputes**: `start_dispute/2`, `confirm_dispute_deposit/2`, `cancel_dispute/2`, `list_disputes/0`, `list_disputes_for_market/1`, `list_disputes_for_account/1`, `list_disputes_by_status/1`, `get_dispute/2`, `has_flagged?/2`, `dispute_count/1`, `live_dispute_count/1`
- **Subaddress attribution** (O(1) for Monero.Poller): `get_quote_by_subaddress/1`, `get_dispute_by_subaddress/1`, `get_market_by_subaddress/1`
- **Reads**: `get_market/1`, `list_markets/0`, `list_markets_by_status/1`, `list_markets_by_category/1`, `list_markets_for_creator/1`, `list_votes_for_market/1`, `has_voted?/2`
- **Payouts**: `claim_payout/3` (positions), `claim_dispute_refund/3` (disputes), `mark_position_paid_out/2`, `mark_dispute_refunded/2`
- **Display projections**: `position_payout/2`, `mid_probability/2`, `pool_invariant/1`, `odds_history/1`, `dispute_stake_for_market/1`
- **Federation revenue**: `federation_ledger/0`
- **Storage**: `replicate_entries/1` (called by `Storage.Replicator` to apply WAL entries received from peers)

No other Markets module is imported by any other domain.

## Events

**Publishes**:
- `MarketCreated` — `:awaiting_deposit` market persisted with deposit subaddress
- `MarketDepositConfirmed` — creation deposit confirmed; market `:awaiting_deposit → :pending`
- `MarketActivated` — survived the pending window; `:pending → :active`
- `MarketRejected` — downvoted out; `:pending → :rejected`; deposit accrues to the federation
- `MarketExpired` — betting closed; awaiting resolution
- `QuoteCreated` — user clicked Buy; deposit subaddress + locked-in price returned
- `QuoteFilled` — deposit confirmed; Quote consumed into a Position; AMM updates atomically
- `PositionOpened` — legacy synchronous path
- `PositionPaidOut` — federation completed an outflow for this position; carries payout txid
- `PositionCancelled` — pending position released (e.g. on void)
- `ResolutionSubmitted` — creator or operator entered an outcome
- `ResolutionReversed` — operator changed outcome during dispute window
- `DisputeFlagged` — dispute deposit confirmed (dispute went `:live`); carries new total live count
- `DisputeReReviewTriggered` — exactly once per ack cycle, when live count crosses the threshold
- `DisputesAcknowledged` — guardians ack-confirmed creator's resolution; settle gate cleared
- `DisputeResolved` — per-dispute terminal outcome; carries `:resolved_for` or `:resolved_against`, refund amount, slashed amount
- `MarketSettled` — payouts complete, fees collected, atomic
- `MarketVoided` — refunds executed; `reason` ∈ `:operator | :creator_no_show | :guardian_undecidable`
- `DepositBurned` — creator's deposit forfeited on `:rejected` (legacy event name; the funds accrue to federation revenue)
- `CommentReceived` — a verified Nostr comment event (kind 1) referencing one of the venue's markets was ingested by `Comments.Inbox`. Carries `event_id`, `market_id`, `author_pubkey`, `content`, `created_at` so subscribed LiveViews can append without re-fetching the inbox. Fires exactly once per distinct event_id (post-dedup); relay echoes are silently absorbed by Inbox dedup and do NOT produce additional `CommentReceived` events.

**Consumes**:
- Federation events (informational; the payout state machine is owned by the Federation domain — Markets only sees the Position / Dispute transition to its terminal `:paid_out` / `:refunded_*` via the WAL after `Federation.Signer` calls back into `Cashier.mark_paid_out/2` or `Cashier.mark_dispute_refunded/2`)

## Invariants

- Every Markets service entry point (Voter, Resolver, Disputer, Trader, Maker, Cashier) MUST call `PerpWalk.Guards.ensure_operational!/0` at the top. When the system is halted, writes refuse with `PerpWalk.Guards.SystemHaltedError`; no Markets state mutation can land while a halt class is active
- A market's pool MUST satisfy `K_new ≥ K_old` after every trade. K is non-decreasing under FPMM-with-splitting; operator-favouring ceiling rounding means any fractional remainder grows the product rather than shrinking it
- The AMM MUST charge a 1.5% spread on every trade — 1.25% accrues to the federation revenue ledger and 0.25% accrues to the market creator
- The Calibration Leaderboard MUST exclude voided markets from both numerator and denominator. The ranking MUST surface only rank, handle, wins, total, and win percentage — no piconero values, no per-market positions, no off-handle identifiers
- A position's `amount_paid` MUST equal the AMM cost at trade time
- Settlement MUST be atomic: winners credited and losers consumed in a single compound write, or fail entirely
- A market MUST resolve exactly once (resolution can be reversed during dispute window, but settlement happens once)
- A voted market MUST count at most one vote per `(account_id, market_id)`
- A disputed market MUST count at most one dispute per `(account_id, market_id)`
- A creator MUST NOT submit `:void` directly — `:void` is operator-only via `override_resolution/2`. A creator who can't resolve lets the deadline lapse; the Scheduler then auto-voids with `reason: :creator_no_show`
- A market past `resolution_deadline + grace` without resolution MUST be voided automatically by the Scheduler with `reason: :creator_no_show` (from `:expired`) or `:guardian_undecidable` (from `:resolving`)
- Settle MUST refuse while live disputes exceed the re-review threshold and have not been acknowledged
- Acknowledging or reversing in `:resolving`, or voiding from `:resolving`, MUST resolve every `:live` dispute to a terminal status (`:resolved_for` or `:resolved_against`) atomically
- A dispute's `slashed_amount_piconeros` MUST be 0 on `:resolved_against` and `0 ≤ slashed ≤ stake` on `:resolved_for`
- A dispute refund Payout MUST carry no `position_id` and a kind of `:dispute_refund_full` or `:dispute_refund_partial`
- Federation revenue MUST be derived read-only from existing Store data (slashed disputes + rejected markets + spread on settled markets); no separate ledger persistence
- Every `Quote` and the `Position` it fills MUST carry the `spread_piconeros` captured at AMM quote time; settlement-time accounting reads it without re-deriving from the original pool state
- `Federation.Ledger.withdrawable_piconeros/0` MUST equal `total_earned − federation_income_drawn`; federation withdrawal Payouts are rules-gated on this value at sign time so a stale console snapshot cannot authorise an over-draw

---
