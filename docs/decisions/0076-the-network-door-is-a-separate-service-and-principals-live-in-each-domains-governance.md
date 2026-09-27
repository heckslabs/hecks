# The network door is a separate service, and principals live in each domain's Governance

**Status:** Accepted — not yet implemented. Date: 2026-09-27. Nothing below is built. This ADR builds on [ADR 0062](0062-mcp-servers-need-real-authentication-before-any-network-transport.md) and [ADR 0072](0072-the-mcp-door-token-waits-for-a-real-need-and-a-tool-allowlist-comes-first.md), and settles the first question of the map in `docs/wayfinder/mcp-network-door/` and part of the second.

## Context

The maintainer said on 2026-09-27 that a network-facing MCP door is wanted. ADR 0062 says a network door is a new door, not a flag, and needs real authentication first. ADR 0072 says the token's verified principal replaces the caller-supplied `role:` and `actor_id:`, and that roles are looked up through Governance. That leaves two questions that everything else waits on: where a principal lives, and where the door runs.

Today the door calls `Hecks.as_caller(role:, actor_id:)` (`lib/hecks/storehouse.rb`), and `refuse_role_mismatch` (`lib/hecks/runtime/command_rules/authorization.rb`) compares the claim to the command's role, or to a Governance role assignment when an `actor_id` is given. The Rust host's invoke path takes `role` from the request body (`rust/host/src/server.rs`).

## Decision

1. **A principal is a role assignment inside a domain's own Governance,** as `actor_id` already works. A verified token names a principal, and the domain's Governance says what that principal may do. A domain that has no assignment for the principal refuses the call. There is no separate identity provider.
2. **The network door is a separate service.** It is a new door process of its own, reached over the network, that calls the runtime. The existing Rust host and the stdio door stay as they are. This is the option the maintainer chose over adding the door to the existing host process, on the grounds that it keeps the host's internal protocol off the network edge.

## Consequences

- No new dependency and no new trust boundary: identity and permission stay in the place the grant check already reads.
- A caller that works across several domains needs a role assignment in each one. A domain that has never heard of the principal refuses, so onboarding a caller to a domain is an explicit step in that domain.
- Who creates and removes a principal is whoever administers that domain's Governance, not a central service.
- The network door is a second deployable with its own release and exposure, and its tool implementations are not the host's.
- The token format, how tokens are minted, revoked and rotated, and how the door reaches a domain are not decided here.

## Alternatives considered

- **One identity provider.** One place to create and remove a caller, with Governance still saying what a principal may do. Not chosen: it adds a dependency and a trust boundary this design does not need yet.
- **The door inside the Rust host.** One deployable, but it puts the tool surface beside the dispatch path that needed a security fix on 2026-09-27. Not chosen.

## Open items

These are the remaining questions of `docs/wayfinder/mcp-network-door/`:

- Which transport the network door speaks, and where TLS ends (the rest of ticket 02).
- Token format and lifecycle (ticket 03): what a caller presents, and how a token is minted, expires, is revoked and is rotated.
- Composing with Governance (ticket 04): how a verified principal replaces `role:` and `actor_id:`, and whether the read tools require a principal on the network door.
- Rust host parity (ticket 05), and what must be tested before it ships (ticket 06).
- How the separate service reaches a domain: loading it in its own process, or calling a running host. Not asked yet.
