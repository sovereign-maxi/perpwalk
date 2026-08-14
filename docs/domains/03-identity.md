# PERP WALK — Identity Domain

Anonymous, capability-based authentication. The keyphrase IS the account. No email, no password, no recovery.

---

## Purpose

Identity provides PERP WALK's auth model: a 6-word access code (Locksmith keyphrase) that the user holds. The Argon2id derivation of the normalized keyphrase is the only persistent identifier server-side, and even that is not stored — it's recomputed every request from the session cookie or fresh user input. There is no recovery, no reset, no email confirmation, no IP correlation, no registry of "known" accounts.

The user's possession of the keyphrase is the credential. Once they prove possession to the web layer (paste at `/auth/login` or generate at `/auth/generate`), `PerpWalk.Identity.Sessions.create/1` mints an opaque server-side `session_id` (32 bytes of `:crypto.strong_rand_bytes`) bound to the `account_id`. The signed Phoenix session cookie carries ONLY that `session_id` — never the `account_id` itself. Subsequent requests resolve the cookie through `Sessions.lookup/1`; revoked sessions return `:not_found` even when the cookie's HMAC is still cryptographically valid. Server-side revocation is the gate against stolen cookies.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Keyphrase** | A 6-word access code generated via Locksmith (e.g. `AMBER-FROST-DELTA-NINE-WOLF-APEX`). The credential. Held by the user, never persisted server-side. |
| **Account ID** | Argon2id hex digest of the normalized keyphrase (Locksmith `key.v1` fixed salt, 3 passes over 64 MiB, 32-byte raw tag). Opaque 64-char hex string used as foreign key everywhere markets, votes, positions, and quotes reference an account. The memory-hard derivation lifts the brute-force floor to millions of years per account against a 48-bit keyphrase entropy space. |
| **Handle** | Friendly display string deterministically derived from the `account_id` via HMAC-SHA256 + curated word lists. Format: `adjective-animal-NNNN` (e.g. `swift-otter-7421`). Same keyphrase always produces the same handle — nothing to store, nothing to recover. |
| **Per-venue Nostr keypair** | A BIP-340 Schnorr keypair HKDF-derived from the normalized keyphrase using salt `"perp-walk-nostr-v1"`. Used by the user to sign Nostr comments on PERP WALK markets. The derivation is scoped to this venue only — same keyphrase always produces the same keypair on PERP WALK with zero cryptographic relationship to the user's main Nostr identity. Letting users log in with their existing `npub` would link betting positions to a persistent public reputation graph; that's the failure mode the per-venue derivation closes. |
| **Nostr handle** | Friendly display string derived from a Nostr pubkey via `nostr_handle_for/1` — same `adjective-animal-NNNN` shape as the account-id-derived handle but with a distinct HMAC domain separator (`"perpwalk.nostr-handle.v1"`). The two handle spaces are intentionally disjoint so the same user's account-handle and nostr-handle won't collide and can't be cross-correlated from the handle alone. |

## Aggregates

**Account** — pure derivation module
- `derive_from_keyphrase/1` — normalises the keyphrase via Locksmith (`trim + uppercase + hyphen-separator`), hashes it, and computes the handle. Returns `{:ok, %{account_id, handle, normalized_keyphrase}}` or `{:error, :empty_keyphrase}`.
- `handle_for/1` — derives just the handle from a known `account_id`. HMAC-SHA256 with a versioned domain separator (`"perpwalk.handle.v1"`); 16-bit slices keep modulo bias <0.2% per segment.
- `derive_nostr_keypair/1` — HKDF-SHA256 from the normalized keyphrase with salt `"perp-walk-nostr-v1"` (RFC 5869 single-iteration extract+expand for 32 bytes). The output is the secp256k1 private key; the x-only BIP-340 pubkey is computed via `Cashew.pubkey_from_privkey/1` with the leading parity byte stripped. Returns `{:ok, {seckey, xonly_pubkey}}` (both 32-byte binaries) or `{:error, reason}`. Domain separation from `handle_for/1` means leakage of one tells nothing about the other.
- `nostr_handle_for/1` — derives a friendly handle from a Nostr pubkey using HMAC-SHA256 with a distinct domain separator (`"perpwalk.nostr-handle.v1"`). Same `adjective-animal-NNNN` shape as `handle_for/1` but a different namespace, so an account's two handles cannot be cross-correlated from the handle alone.
- No state, no IO. Same input → same output, on every node.

**Sessions** — server-side session registry (GenServer + two ETS tables)
- Two-table split: a `:public` ETS holds `{session_id, account_id, created_at_ms}` rows (the account binding); a separate `:private` ETS owned by the Sessions GenServer holds `{session_id, nostr_seckey}` rows. The public table is only ever read for account-binding lookups; the seckey table is read only via a GenServer call so no other process can dump it.
- `create/2` mints a fresh 32-byte `:crypto.strong_rand_bytes` session_id bound to an `account_id`. Accepts a `:nostr_seckey` opt — the per-venue Nostr secret key derived from the user's keyphrase at login. Account-binding row is WAL-persisted via a `:session_created` entry; the seckey row stays in-memory only on the `:private` table.
- `lookup/1` returns `{:ok, account_id}` for a live session or `{:error, :not_found}` for revoked / never-minted / expired.
- `lookup_nostr_seckey/1` returns `{:ok, seckey}` for a live session that was created with a `:nostr_seckey` opt, `{:error, :no_nostr_key}` for sessions without one, or `{:error, :not_found}` for unknown / expired session_ids. Called by the market detail LiveView at comment-submit time to sign the kind:1 comment event without re-deriving from the keyphrase.
- `revoke/1` and `revoke_all_for_account/1` invalidate cookies server-side at logout and on operator-initiated rotation. Both clear the bound `nostr_seckey` along with the account binding — there is no path to recover the seckey after revoke short of re-logging in.
- 30-day TTL from creation; lookup-time check closes the up-to-an-hour window between sweep ticks.
- Per-account cap of 20 active sessions: a 21st login revokes the oldest existing session for the same `account_id` before minting the new one. Bounds the DoS amplifier of a Tor-circuit-rotating attacker accumulating sessions against one account.
- Account-binding sessions survive a Phoenix restart via WAL replay (`init/1` calls `replay_wal/0` and rebuilds the public table from the durable log). The Nostr seckey does NOT — it lives only in the `:private` in-memory table and is re-derived from the keyphrase on next login.

**Gate** — Tor-circuit-aware request gate (Plug)
- Extracts a per-circuit hash via `Seer.Circuit.Extractor` (IP is meaningless inside Tor — every request arrives on 127.0.0.1).
- Classifies the operation by method + path and applies `Seer.RateLimiter` per-circuit per-operation. Unknown classifications fail closed (HTTP 429) — a future operation added without a matching supervisor limit silently bypassing rate limiting is the failure mode this fixes.
- Optional PoW bypass via `Seer.Challenge` when a circuit is rate-limited but the client is willing to spend compute. Failed PoW verifications escalate against the circuit via `Seer.Escalation.record/1`.

**PerpWalkWeb.Auth** — Phoenix plug + LiveView `on_mount` callback
- `log_in/3`, `log_out/1`, `fetch_current_account/2`, `on_mount/4` — the seam between Identity's pure derivation logic and Phoenix's session cookie.
- `log_in/3` accepts a `:nostr_seckey` opt, validated as a 32-byte binary, threaded through to `Sessions.create/2`. Both auth flows (`auth_controller.ex` `generate` and `login`) call `Identity.Facade.register/0` / `authenticate/1`, which now include the derived Nostr keypair in their return shapes, and pass the seckey forward to `Auth.log_in/3`.

## Commands

| Command | Description |
|---------|-------------|
| Register | Generate a fresh 6-word keyphrase via Locksmith, derive `account_id` and `handle`, return all three for one-time display. |
| Authenticate | Hash a user-supplied keyphrase, return `{:ok, account_id, handle}` for any non-empty input. There is no allow-list — any well-formed keyphrase is a valid account. The session cookie that the web layer subsequently sets is what gates real operations. |
| Handle for account_id | Pure derivation — used by views to render friendly display strings without holding the keyphrase. |

## Boundaries

**Owns**: Keyphrase normalization, account_id derivation, handle generation (HMAC + word lists)

**Depends on**:
- `locksmith` library — keyphrase generation (`Locksmith.generate(:keyphrase, words: 6)`) and normalization/hashing (`Locksmith.Key.normalize/1`, `Locksmith.Key.hash/1`)

**Depended on by**:
- `PerpWalkWeb.Auth` — session-backed authentication for the public web surface; uses `authenticate/1` to validate paste, `register/0` to mint, `handle_for/1` for nav display
- Views that surface a friendly handle alongside a foreign-key `account_id`

## Published Language (Identity.Facade)

External callers interact with Identity exclusively through `PerpWalk.Identity.Facade`:

- `register/0` → `{:ok, %{display_key, account_id, handle, nostr_seckey, nostr_pubkey}}` — fresh keyphrase + derived identity + derived per-venue Nostr keypair
- `authenticate/1` → `{:ok, %{account_id, handle, nostr_seckey, nostr_pubkey}}` or `{:error, :empty_keyphrase | :invalid}` — validate paste; identical Nostr keypair returned every time for the same keyphrase
- `handle_for/1` → `String.t()` — derive account-id-namespaced handle from a known `account_id`

The Nostr-pubkey-namespaced handle (used in comment rendering) is derived via `Identity.Account.nostr_handle_for/1` directly — accepted as a public seam from views since it's a pure HMAC computation with no domain-internal state.

No other Identity module is imported by any other domain.

## Events

Identity publishes no events. There is no registration ledger and no auth log by design. The only durable state is the account-binding rows in the Sessions WAL (replayed at boot to rebuild the public ETS); seckey rows remain in-memory only. Rate-limit telemetry runs through `Seer.RateLimiter`'s own metrics, not Identity events.

## Invariants

- The raw keyphrase MUST NEVER be persisted, logged, or transmitted server-to-server.
- An account MUST be identified ONLY by the Argon2id tag of its normalized keyphrase (`Locksmith.Key.hash/1`; 3 passes over 64 MiB, raw 32-byte tag, hex-encoded).
- The system MUST NOT provide any keyphrase recovery mechanism (lost keyphrase = lost account, full stop).
- The system MUST NOT collect email, phone number, IP address, or any external identifier as part of identity.
- The system MUST NOT accept "bring your own npub" as a login path. The per-venue Nostr keypair derivation is the only Nostr identity surface for the user — log-in via existing Nostr identity would link betting positions to a persistent public reputation graph and defeat the anonymity model.
- The handle derivation MUST be deterministic — same `account_id` always yields the same handle, with no per-instance state. The same property holds for `nostr_handle_for/1` over a pubkey input.
- The per-venue Nostr keypair MUST be HKDF-derived deterministically from the keyphrase (salt `"perp-walk-nostr-v1"`); same keyphrase always produces the same keypair on this venue.
- The per-venue Nostr seckey MUST NEVER be persisted to disk. Held only in the in-memory Sessions ETS row for the lifetime of the user's session; gone on logout, revoke, or BEAM restart.
- Account creation MUST be free (no XMR cost, no work-factor gate at the Identity layer; brute-force defense is a web/network-layer concern, not an Identity invariant).

---
