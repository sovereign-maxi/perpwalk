# PERP WALK — Domain Overview

## What It Is

PERP WALK is a privacy-first prediction market for binary outcome events, settled in Monero. Users deposit XMR per-trade, take positions on community-created markets, and withdraw winnings — all in XMR. No accounts, no KYC, no fiat, no trace. The venue is a `.onion` hidden service. No clearnet, no exceptions.

The lifecycle is community-moderated end to end: anyone can create a market (against an XMR escrow that gets forfeited if the community downvotes the listing), the creator submits a YES/NO resolution at expiry (`:void` is operator-only — creators who can't resolve let the deadline lapse and the market auto-voids), and the community can stake XMR to dispute a resolution they believe is wrong. Rejected disputes are partially slashed, upheld disputes are fully refunded. Federation revenue (slashes + forfeited creator deposits + the federation's spread share) is tracked as a derived ledger and only ever moves through the same 2-of-3 federation signing pipeline as any other Monero outflow.

## Architecture

XMR-only. **2-of-3 federation, all nodes equal.** Polymarket-style FPMM (Fixed Product Market Maker) with conditional-token collateral splitting. WAL-backed state with bidirectional replication. Event-driven telemetry. Tor hidden services for user and admin endpoints. Nostr (Tor-tunneled) is the inbound/outbound distribution layer for market lifecycle events and anonymous comments.

Three guardians run identical code, identical config, and identical secrets. Every Monero outflow requires 2-of-3 signatures via `Darks.Multisig` over the `cartel` federation runtime; the signing responsibility is symmetric across all three. **Which guardian serves the public onion is purely an external routing decision** — the public `.onion` HiddenService key currently lives on one guardian; OnionBalance across all three is the planned post-launch improvement. Promoting a different guardian is publishing the descriptor from its keys; nothing in the app code differentiates them. Failover is manual.

```
                                Federation (2-of-3)
              ┌─────────────────────────┬──────────────────────────┐
              │                         │                          │
              ▼                         ▼                          ▼
          Node A                    Node B                     Node C
   (anchor jurisdiction 1)  (anchor jurisdiction 2)   (anchor jurisdiction 3)

┌─────────────────────────────────────────────────────────────┐
│                       PERP WALK                             │
│                                                             │
│  ┌────────────────────┐  ┌──────────────────┐               │
│  │      Markets       │  │      Monero      │               │
│  │                    │  │                  │               │
│  │  Lifecycle         │  │  Per-trade       │               │
│  │  AMM (FPMM)        │  │   subaddresses   │               │
│  │  Positions         │  │  Deposit poller  │               │
│  │  Quotes / Fills    │  │  (Darks.Client)  │               │
│  │  Disputes          │  │                  │               │
│  │  Resolution        │  └────────┬─────────┘               │
│  │  Federation rev    │           │                         │
│  │  Comments          │           │                         │
│  │  Leaderboard       │           │                         │
│  │  Publishers.Nostr  │           │                         │
│  └─────────┬──────────┘           │                         │
│            │                      │                         │
│  ┌─────────┴──────────────────────┴─────────┐               │
│  │             Storage (WAL + ETS)          │               │
│  └──────────────────────────────────────────┘               │
│                                                             │
│  ┌──────────────────┐  ┌───────────────────┐                │
│  │     Identity     │  │     Telemetry     │                │
│  │                  │  │                   │                │
│  │  Keyphrase →     │  │  Alerts           │                │
│  │   account_id     │  │  Metrics          │                │
│  │  Handle derive   │  │  Health           │                │
│  │  (no storage)    │  │  Nostr DMs        │                │
│  └──────────────────┘  └───────────────────┘                │
│                                                             │
│                          ┌───────────────────┐              │
│                          │     Reserves      │              │
│                          │                   │              │
│                          │  Snapshot         │              │
│                          │  Attestation      │              │
│                          │  Sign / publish   │              │
│                          │  /api/reserves    │              │
│                          │  + NIP-33 Nostr   │              │
│                          └───────────────────┘              │
│                                                             │
│  ┌──────────────────────────────────────────┐               │
│  │      Federation (Cartel + Darks)         │               │
│  │  Cluster mesh, Rules, Payout,            │               │
│  │  2-of-3 multisig signing, peer health    │               │
│  └──────────────────────────────────────────┘               │
│                                                             │
│  ┌──────────────────────────────────────────┐               │
│  │             Events (EventBus)            │               │
│  └──────────────────────────────────────────┘               │
└─────────────────────────────────────────────────────────────┘
```

## Domains

| # | Domain | Purpose |
|---|--------|---------|
| 1 | [Markets](01-markets.md) | Market lifecycle, FPMM pricing (Polymarket-style with collateral splitting), positions, quotes/fills, creator-driven resolution, staked disputes, settlement, federation-revenue ledger, anonymous Nostr comments, calibration leaderboard, Nostr lifecycle publisher |
| 2 | [Monero](02-monero.md) | Per-trade subaddresses, deposit polling and dispatch, wallet RPC; outflows are owned by Federation |
| 3 | [Identity](03-identity.md) | Keyphrase → account_id derivation, handle derivation, per-venue Nostr keypair derivation (HKDF) for comment signing, session-bound seckey held in-memory only |
| 4 | [Storage](04-storage.md) | WAL, ETS, DETS cold tier, bidirectional peer-to-peer WAL replication, persistence |
| 5 | [Telemetry](05-telemetry.md) | Alerts, metrics, health monitoring, Nostr DMs |
| 6 | [Events](06-events.md) | EventBus, domain events, Display protocol |
| 7 | [Federation](07-federation.md) | Cartel runtime, 2-of-3 multisig, Payout, Rules engine, peer health, federation-income withdrawal |
| 8 | [Reserves](08-reserves.md) | Proof-of-reserves cycle: snapshot, attest, sign, publish via `/api/reserves` + NIP-33 Nostr + on-chain wallet |

**Nostr substrate** (lives in `PerpWalk.Nostr.*`, not a bounded context of its own):
- `Nostr.Relay.Client` — one-shot Tor-tunneled publish to a single relay
- `Nostr.Relay.Subscriber` + `Nostr.Subscription.Supervisor` — persistent inbound subscribers, one per configured relay, sending NIP-01 `REQ` for `kind=1, #t=perpwalk-market-comment`
- `Nostr.Event` — pure NIP-01 parsing + BIP-340 Schnorr signature verification
- `Nostr.Frame` — NIP-01 wire-format codec

Used by the Markets `Publishers.Nostr` (lifecycle events as NIP-33 kind 30819) and `Comments` subsystem (NIP-01 kind:1 notes with a `["t", "perpwalk-market-comment"]` topic tag and a `["a", "30819:<venue_pubkey>:<market_id>"]` NIP-33 reference to the market), as well as by Reserves (`ProofGenerated` events as NIP-33 kind 30078). All outbound + inbound Nostr traffic routes through the Tor HTTP CONNECT tunnel; production refuses to boot without `TOR_HTTP_TUNNEL_PORT`.

## Cross-Domain Dependencies

All cross-domain communication goes through facades. No module imports another domain's internal modules directly.

| From | To | Via |
|------|-----|-----|
| Markets | Storage | `Storage.Facade` for paths; `Markets.Store` writes the markets-domain WAL directly per the WAL-facade exemption |
| Markets | Monero | `Monero.Facade.create_subaddress/0` for per-trade and per-dispute subaddresses |
| Markets | Federation | `Federation.Facade.enqueue_payout/3` (winner / position refund), `Federation.Facade.enqueue_dispute_refund/3` (dispute refund), `Federation.Facade.enqueue_creator_lp_return/4` (creator LP residual / void return) |
| Markets (operator console) | Federation | `Federation.Facade.enqueue_federation_income_withdrawal/3` (operator-initiated sweep of federation revenue) |
| Federation | Markets | `Markets.Facade.get_position/1`, `get_market/1`, `get_dispute/2` for rule evaluation; `mark_position_paid_out/2`, `mark_dispute_refunded/2` for post-signing finalisation |
| Federation | Monero | `Darks.Multisig` (federated signing rounds, tx submission) |
| Monero | Markets | `Markets.Facade.fill_quote/2`, `Markets.Facade.confirm_dispute_deposit/2`, `Markets.Facade.confirm_market_deposit/1` from `Monero.Poller` when deposits confirm; `get_quote_by_subaddress/1` and siblings for O(1) deposit attribution |
| Monero | Federation | `Federation.Facade.halt_signing/0` and `Federation.Facade.record_audit/2` from `Monero.Poller` on reorg / unconfirmed-drop detection |
| Identity | (none) | `account_id` is derived from the keyphrase on every request. Sessions' account bindings persist via the WAL (restart-survivable); the per-venue Nostr seckey is HKDF-derived from the keyphrase at login and held in a `:private` ETS row for comment signing, in-memory only. |
| Reserves | Markets | `Markets.Facade.list_all_positions/0`, `list_markets/0`, `list_disputes/0` for the liabilities side of each proof cycle |
| Reserves | Monero | `Monero.Facade.balance/0` for the reserves side (`balance` field — `unlocked_balance` produces false deficits on payout-change and deposit-lock windows; see `Reserves.Source` for the documented trade-off) |
| Telemetry | All domains | Read-only observation via facades and EventBus |

## Deposit-to-Payout Flow

```
User → Tor → LiveView (whichever guardian is fronting the surface)
  → Identity (paste keyphrase → Locksmith Argon2id → account_id; signed session cookie)
  → Markets.Trader.create_quote → Monero.Facade.create_subaddress (fresh per-trade subaddress)
  → User sends XMR to subaddress
  → Monero.Poller (poll, detect at the configured depth — 10 confs default) → Markets.Trader.fill_quote
  → ... user holds position; market expires ...
  → Markets.Resolver.submit_resolution_by_creator (creator, via /portfolio Resolve modal — :yes or :no)
  → :resolving — dispute window opens (24h)
       │
       │  Optional: any user can stake to dispute
       │  → Markets.Disputer.start_dispute → fresh subaddress
       │  → User sends XMR stake
       │  → Markets.Disputer.confirm_deposit on confirmation → dispute is :live
       │  → Live count past threshold blocks settle until guardians act
       │
  → Guardian review (acknowledge | reverse | void via Markets.Console)
  → Markets.Resolver.settle (winners → :settled_winner, losers → :settled_loser, atomic)
  → ... users (and resolved disputers) request payouts ...
  → Markets.Cashier.claim_payout (positions) | claim_dispute_refund (disputes)
  → Federation.Facade.enqueue_payout | enqueue_dispute_refund
  → Federation.Rules (independent on every node, dispatches by Payout kind)
  → Federation.Signer (2-of-3 Monero multisig signing rounds)
  → Darks.Multisig.submit (tx broadcast)
  → Markets-side finalisation: Position → :paid_out OR Dispute → :refunded_full / :refunded_partial
```

If a creator never submits a resolution, the Scheduler auto-voids past `resolution_deadline + grace` with `reason: :creator_no_show`; positions are refunded and any outstanding live disputes auto-resolve as `:resolved_against` (full refund, no slash).
