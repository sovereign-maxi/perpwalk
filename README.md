# PERP WALK

Markets without permission.

Anonymous prediction markets denominated in Monero. Users deposit XMR, take positions on community-created binary outcome markets via a constant-product AMM, and withdraw winnings — all in XMR, all over Tor. No accounts, no KYC, no fiat, no trace.

Reference implementation of a Tor-native Monero-denominated prediction-market runtime. Single-federation, `darks`-backed multisig, Phoenix + LiveView, WAL-backed state with leader/follower replication.

Protocol specification: [github.com/sovereign-maxi/perpwalk-docs](https://github.com/sovereign-maxi/perpwalk-docs).

## Architecture

2-of-3 federation. Constant-product AMM with WAL-backed state and leader/follower replication. Event-driven telemetry. Tor hidden services for all endpoints. Per-trade Monero subaddresses — no aggregated user balances.

Every Monero outflow requires two of three node signatures via `darks` native multisig. The federation **signing** role is symmetric across all three nodes; the **storage** role nominates one leader who accepts writes while the other two tail its WAL.

Eight bounded contexts under a `rest_for_one` supervision tree:

| Context | Responsibility |
|---------|---------------|
| **Markets** | Lifecycle, AMM pricing, positions, quotes/fills, creator-driven resolution, staked disputes, settlement, federation-revenue ledger |
| **Monero** | monerod / wallet-rpc integration, per-trade subaddresses, deposit polling (via `darks`) |
| **Federation** | Cartel runtime, 2-of-3 multisig, Payout state machine, Rules engine, peer health |
| **Reserves** | Proof-of-reserves cycle, NIP-33 Nostr publication, signed attestations (via `vault` + `cashew`) |
| **Identity** | Keyphrase-derived account ids, handle generation; persists nothing (via `locksmith`) |
| **Storage** | WAL, ETS, DETS, replication, persistence, recovery |
| **Telemetry** | Alert rules, health scoring, Nostr DM alerts |
| **Events** | EventBus, domain events, Display protocol |

Two Phoenix endpoints, each intended for a dedicated Tor hidden service:

- **PerpWalkWeb** (dev `:4000`, prod `$PORT`) — markets UI + LiveView
- **PerpWalkAdminWeb** (dev `:4001`, prod `$ADMIN_PORT`) — read-only operator dashboard

## Prerequisites

- Elixir 1.19 / OTP 27 (see `.tool-versions`)
- Rust (stable) for the Cashew NIF (BIP-340 Schnorr for Nostr publication)
- [monerod](https://www.getmonero.org/) — pruned full node
- [monero-wallet-rpc](https://www.getmonero.org/) — wallet daemon, one per federation node
- Tor — required for production (HTTP CONNECT tunnel outbound; hidden services inbound)

## Setup

```bash
mix deps.get
git config core.hooksPath hooks
```

## Development

```bash
iex -S mix phx.server

mix test                    # unit
mix test --only integration # integration

# Actor simulation harness
mix sim.events --scenario baseline --ticks 600 --seed 42 --validate
```

- Markets: <http://localhost:4000/>
- Admin:   <http://localhost:4001/admin/dashboard>

See [sim/README.md](sim/README.md) for the simulation harness.

## API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/reserves` | Current proof-of-reserves snapshot |
| `GET` | `/api/reserves/history` | Historical reserve proofs |

The user-facing markets surface is rendered LiveView, not a REST API.

## Reference-implementation defaults

| Operation | Fee |
|-----------|-----|
| Deposit | Free |
| Position | 3% spread (built into pricing) |
| Settlement | Free (spread already collected) |
| Withdrawal | XMR network fee passed through to user |
| Market creation | XMR escrow — returned on resolution; forfeited to federation revenue if community-rejected |
| Dispute | XMR stake (`max(0.1 XMR, traded_volume × 0.5%)`) — partial slash on rejection, full refund on upheld |

Fees are configurable per deployment — the numbers above are the reference implementation's defaults.

## Documentation

| Doc | Purpose |
|-----|---------|
| [domains/00-overview.md](docs/domains/00-overview.md) | Architecture and domain map |
| [domains/01-markets.md](docs/domains/01-markets.md) | Markets domain — lifecycle, AMM, disputes, settlement |
| [domains/02-monero.md](docs/domains/02-monero.md) | Monero domain — subaddresses and deposit polling |
| [domains/03-identity.md](docs/domains/03-identity.md) | Identity domain — keyphrase auth |
| [domains/04-storage.md](docs/domains/04-storage.md) | Storage domain — WAL, ETS, replication |
| [domains/05-telemetry.md](docs/domains/05-telemetry.md) | Telemetry domain — alerts and health |
| [domains/06-events.md](docs/domains/06-events.md) | Events domain — EventBus and catalog |
| [domains/07-federation.md](docs/domains/07-federation.md) | Federation domain — 2-of-3 multisig, Payout, Rules |
| [domains/08-reserves.md](docs/domains/08-reserves.md) | Reserves domain — proof-of-reserves cycle |
| [prds/00-product-requirements.md](docs/prds/00-product-requirements.md) | Product requirements |

## Dependencies

```elixir
{:blueprint, path: "../blueprint"},
{:seer,      path: "../seer"},
{:locker,    path: "../locker"},
{:vault,     path: "../vault"},
{:cashew,    path: "../cashew"},
{:darks,     path: "../darks"},
{:cartel,    path: "../cartel"},
{:locksmith, path: "../locksmith"},
```

All primitives are published under [github.com/sovereign-maxi](https://github.com/sovereign-maxi).

## License

MIT. See [LICENSE](LICENSE).
