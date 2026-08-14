# PERP WALK — TODO

Research-heavy TODO for PERP WALK as an OSS reference for Monero-native prediction markets.

XMR-only. Any item that would replace XMR with another chain is out of scope.

## Cryptographic primitives

- [ ] Confidential AMM state via Pedersen commitments — pool reserves stored as commitments, trades update homomorphically; observers see the curve moving without seeing individual trade sizes
- [ ] Zero-knowledge proof of position — prove "I hold position on market X, side Y, size ≥ N" without revealing which
- [ ] Ring signatures on community listing votes — proves an eligible voter voted without revealing which one
- [ ] Threshold decryption of oracle inputs — creator resolution and dispute evidence encrypted to the federation threshold key, decrypted only after resolution deadline
- [ ] VDF-based settlement gating — verifiable delay function pins settlement to a public unfudgeable moment regardless of federation eagerness

## Chaumian XMR mint

- [ ] Chaumian XMR mint primitive — BDHKE over ed25519, piconero-denominated bearer tokens, mint wallet as RingCT-backed pool. Standalone library / spec; PERP WALK is the reference consumer
- [ ] Deposit-once model — users deposit XMR to the mint once, receive bearer tokens, spend across many Quotes without re-depositing
- [ ] Bearer payout tokens — winnings issued as bearer tokens by default; on-chain XMR redemption is opt-in
- [ ] Bearer position tokens — positions themselves as bearer instruments, transferable off-venue
- [ ] Aggregated redemption path — federation only signs an on-chain outflow when a token is redeemed for XMR

## Product mechanics

- [ ] Recursive markets — markets on the outcome of other markets, meta-prediction, calibration markets
- [ ] Cross-market conditional pricing — joint bets over correlated markets ("A given B"), graph solver with correlation adjustment
- [ ] Perpetual prediction markets — no expiry, funding rate pushes price toward realized probability, requires continuous oracle
- [ ] Parlays — 2-of-N conditional bets paying only if all hit, product of marginal probabilities with correlation adjustment
- [ ] Dutch-auction creator fee — creators bid down their spread share via reverse Dutch auction

## Federation / infra

- [ ] N-of-M dynamic membership — beyond 2-of-3, add / remove guardians via WAL-signed governance action
- [ ] Onion-routed federation cluster — all inter-guardian traffic over Tor hidden services, federation topology opaque to observers
- [ ] Geographic-failover choreography — guardians rotate hosting jurisdictions via handoff dance, zero-downtime jurisdiction hopping

## Oracles / resolution

- [ ] Nostr-native oracle protocol — resolution feeds as signed Nostr events by a configurable oracle set, subscribe-verify-consume
- [ ] Optimistic resolution with fraud proofs — creator submits resolution, any party posts a bonded fraud proof within N hours, reversal + slash on valid proof
- [ ] Guardian dispute-vote prediction pool — guardians vote on disputes with reputation-weighted stake; the dispute itself is a market between guardians
- [ ] TEE-backed dispute verifier — SGX / Nitro Enclave runs a small LLM against dispute evidence, produces attested yes/no with confidence

## UX / distribution

- [ ] Client-side settlement verification — browser JS independently verifies settled markets against on-chain / oracle proofs before showing "you won"
- [ ] Nostr wallet connect for deposits — deposit request pushed to the user's Nostr wallet, approved in-wallet, kills copy-paste-XMR-address friction

## Meta / academic

- [ ] Formal verification of AMM invariants — Coq / Lean proofs for `K_new ≥ K_old`, no over-settlement, no double-payout
- [ ] Pluggable AMM curves — FPMM, LMSR (Hanson), Gaussian, Linear, extensible primitive
- [ ] Load-testing benchmark suite — N synthetic users, realistic trade patterns, WAL replication lag, settlement latency, memory pressure
- [ ] Prediction-market DSL — small language for market types (binary / categorical / scalar / multi-outcome / conditional), compiles to WAL entry types
