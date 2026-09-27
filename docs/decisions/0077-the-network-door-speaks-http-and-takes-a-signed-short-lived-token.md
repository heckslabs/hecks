# The network door speaks HTTP, takes a signed short-lived token, and is tested on a real listener

**Status:** Accepted — not yet implemented. Date: 2026-09-27. Nothing below is built. This ADR builds on [ADR 0062](0062-mcp-servers-need-real-authentication-before-any-network-transport.md), [ADR 0072](0072-the-mcp-door-token-waits-for-a-real-need-and-a-tool-allowlist-comes-first.md) and [ADR 0076](0076-the-network-door-is-a-separate-service-and-principals-live-in-each-domains-governance.md), and settles the rest of the map in `docs/wayfinder/mcp-network-door/`.

## Context

ADR 0076 decided that the network door is a separate service and that principals live in each domain's Governance. Five questions were left before a build could start: the transport and where TLS ends, what a caller presents, what happens to the self-asserted `role:` and `actor_id:`, whether the Rust host's internal protocol is affected, and what must be tested before anyone can reach the door. The maintainer answered each on 2026-09-27, in each case choosing the recommended option below.

The Rust host now trusts its internal dispatch protocol only from a peer on the same host (`rust/host/src/server.rs`, `trusts_internal_dispatch`), so the public internet cannot reach it through a load balancer. The host's web layer already verifies an HMAC-signed session cookie (`rust/host/src/auth.rs`).

## Decision

1. **Transport.** The door speaks MCP over HTTP (streamable, with server-sent events where a stream is needed). TLS is ended by the platform's load balancer in front of the separate door service, like the existing services. The door refuses anything but its own MCP paths before any token check.
2. **What a caller presents.** A signed, short-lived bearer token: an HMAC-signed token naming the principal, an audience and an expiry, in the same family as the host's signed session cookie. The signing key is held in the platform's secrets store and rotated. Revocation is by expiry plus a deny list.
3. **Composing with Governance.** The verified principal replaces `role:` and `actor_id:`. A request that still sends either is refused with a clear message. Even the read tools require a verified principal. This is stricter than the stdio door, on purpose.
4. **The Rust host.** The token check does not reach the host's internal protocol. The host keeps trusting that protocol only from loopback, and the network door verifies tokens itself before it calls the runtime. Parity is the door's own rule, held identical for Ruby and Rust callers, and not a change to the host now.
5. **What must be tested before anyone can reach it.** A forged signature, an expired token, a token for another audience, a revoked token, a request still carrying `role:` or `actor_id:`, and a path the door never routes. Each runs in-process and against a real listener, and the cases join the MCP subprocess specs. A failing one blocks the door's own release, and not the gem's.

## Consequences

- An agent needs a token minted for it before it can read anything through the network door, and a role assignment in the domain's Governance before it can do anything (ADR 0076).
- A token that is stolen works until it expires or is put on the deny list, so its lifetime is a security setting, not a convenience.
- Running the door against a real listener makes the tests slower than in-process ones, but they cover the network edge, where the recent host gap was.
- The host's own internal protocol remains self-asserted from the same host. That gap is smaller since the loopback restriction and is not closed by this ADR.
- The door is a second deployable with its own signing key, its own release and its own exposure.

## Alternatives considered

- **WebSocket.** Simpler streaming, but a second protocol to operate and secure, and a poorer fit for load balancers that time out idle connections. Not chosen.
- **An opaque token looked up in Governance.** Revocation is deleting a row and there is no signing key, but every call needs a Governance lookup and the door needs read access to it. Not chosen.
- **Ignoring `role:` and `actor_id:`.** Friendlier to existing clients, but a caller may think its claim was honoured. Not chosen.
- **A principal for the host's internal protocol too.** Closes the last self-asserted role, but changes every deployed sidecar and the host's wire contract. Not chosen for now.
- **In-process tests only.** Faster and simpler, but they skip the network edge. Not chosen.

## Open items

The decisions above leave the build's own details to be settled when it starts:

- The token's exact claims and encoding, the key rotation interval, and where the deny list is stored and how fast a revocation reaches every door instance.
- How the token names the domain or domains it may reach, given that principals are per domain (ADR 0076).
- How the separate service reaches a domain: loading it in its own process, or calling a running host.
- Rollout: how the first network door is exposed and to whom.
- Rate limiting and abuse handling, which the stdio door never needed.
- Which identity fields the audit log records once a principal is verified.
- Whether one door serves several domains or one door per domain.
