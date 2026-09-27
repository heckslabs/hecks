---
label: wayfinder:map
---

# MCP network door: the way from "wanted" to a decided design

## Destination

A decided design for a network-facing MCP door, specific enough that a build can start: where
principals live, how a caller proves who it is, how that composes with Governance, and what has
to be tested before it ships. Nothing here builds; each resolved ticket lands as an ADR that
builds on [ADR 0062](../../decisions/0062-mcp-servers-need-real-authentication-before-any-network-transport.md)
and [ADR 0072](../../decisions/0072-the-mcp-door-token-waits-for-a-real-need-and-a-tool-allowlist-comes-first.md).

## Notes

- The maintainer answered on 2026-09-27 that a network door is wanted (ADR 0072 open item). ADR
  0062 says a network door is a new door, not a flag, and needs real authentication first; ADR
  0072 says the token's verified principal replaces the caller-supplied `role:` and `actor_id:`,
  roles are looked up through Governance, and forged-token specs are required.
- The per-tool allowlist (ADR 0072 decision 2) is built separately and is not authentication.
- Tracker: local markdown, as in `docs/wayfinder/review-followup/`. A ticket is on the frontier
  when it is open, unclaimed, and everything in `blocked_by` is closed.
- Tickets here are grilling tickets, resolved in a live exchange with the maintainer; an agent
  may gather facts for one but does not answer it.
- Docs rules apply: no client names, no spec counts.

## Decisions so far

## Not yet specified

- Rollout: how the first network door is exposed and to whom, once the design is decided.
- Rate limiting and abuse handling on the network door, which the stdio door never needed.
- Which identity fields the audit log records once a principal is verified.
- Whether one door serves several domains or one door per domain.

## Out of scope

- Any implementation.
- The stdio door's own identity gap beyond what ADR 0072 already decides.
