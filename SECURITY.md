# PERP WALK - Security Policy

PERP WALK is a reference implementation of a Monero-denominated prediction market on Tor. It is not a maintained product and there is no running service operated by this repository. Fixes are best-effort. If you fork PERP WALK and run your own instance, operational security is entirely your responsibility.

## Reporting a vulnerability

**Do not open a public issue.**

Report vulnerabilities privately via GitHub Security Advisories:

**<https://github.com/sovereign-maxi/perpwalk/security/advisories/new>**

This opens a form visible only to the repository maintainers. A CVE can be requested through the same interface once triaged.

## Scope

**In scope**

- Cryptographic defects in the AMM, settlement, or attestation logic
- Logic bugs enabling double-payout, unbacked liability, replay, or theft
- Federation-protocol deviations (multisig signing, replication, quorum handling)
- Recovery-path defects that could lose or corrupt state
- Authentication / rate-limit / abuse-cost bypass
- Vulnerabilities in the shared primitives as they apply to PERP WALK

**Out of scope**

- Attacks on any specific running instance — those are the operator's concern, not this project's
- Findings from unmodified public dependencies already known upstream (report there)
- Denial of service that only affects the reporter's own deployment
- Social engineering, physical attacks, third-party services

## Disclosure

Coordinated disclosure: **90 days** from acknowledgement to public advisory, longer by mutual agreement if the fix genuinely requires it. If the vulnerability is actively exploited, the window shortens.

Reporters are credited in the published advisory unless they request anonymity. Bug bounties are not offered.

## Response expectations

Because PERP WALK is a reference implementation, response times reflect that. A serious cryptographic or double-payout issue will be prioritised. A cosmetic hardening suggestion may sit until a general maintenance pass. Fork it if you need a faster cadence than this project provides.
