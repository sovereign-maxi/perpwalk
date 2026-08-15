# PERP WALK — Security Policy

Security is a first-order concern for PERP WALK. This document describes how to report vulnerabilities and what to expect once you do.

## Reporting a vulnerability

Report vulnerabilities privately via GitHub Security Advisories:

**<https://github.com/sovereign-maxi/perpwalk/security/advisories/new>**

The form is visible only to maintainers. A CVE can be requested through the same interface once the issue is triaged.

Please do not open a public issue for security matters — coordinated disclosure protects users during the fix window.

## Scope

**In scope**

- Cryptographic defects in the AMM, settlement, or attestation logic
- Logic bugs enabling double-payout, unbacked liability, replay, or theft
- Federation-protocol deviations (multisig signing, replication, quorum handling)
- Recovery-path defects that could lose or corrupt state
- Authentication, rate-limit, or abuse-cost bypasses
- Vulnerabilities in the shared primitives as they apply to PERP WALK

**Out of scope**

- Findings from unmodified public dependencies already tracked upstream — please report those to the dependency's maintainers
- Denial-of-service that only affects the reporter's own deployment
- Social engineering, physical attacks, and vulnerabilities in third-party services

## Disclosure

Coordinated disclosure window: **90 days** from acknowledgement to public advisory. Longer windows are negotiable by mutual agreement if the fix requires substantial refactoring; shorter windows apply if the vulnerability is actively being exploited.

Reporters are credited in the published advisory unless they request anonymity.

## Response

Serious cryptographic or double-payout issues are prioritised for immediate triage. Other reports are triaged as quickly as maintainer availability permits. We aim to acknowledge every valid report within 72 hours.

Bug bounties are not offered at this time.
