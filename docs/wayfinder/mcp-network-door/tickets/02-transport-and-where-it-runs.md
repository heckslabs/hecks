---
type: grilling
status: closed
blocked_by: []
claimed_by:
---

# Transport, and where the door runs

## Question

ADR 0062 says a network door is a new door, not a flag on the stdio one. Decide the network
transport it speaks, whether it runs inside the existing Rust host process or as a separate
service, where TLS ends, and how it is reached in a deployment like the Fargate shape (behind a
load balancer and CDN, where the host already found that anything forwarded reaches dispatch).
Say what the door refuses at the network edge before any token check, and whether the stdio door
and the network door share their tool implementations or only their contract.

## Answer

Partly decided 2026-09-27; the ticket stays open. **Where it runs:** a separate service, a new
door process reached over the network that calls the runtime, with the existing Rust host and the
stdio door unchanged (recorded in
[ADR 0076](../../../decisions/0076-the-network-door-is-a-separate-service-and-principals-live-in-each-domains-governance.md)).
**Still open:** the network transport it speaks, where TLS ends, how it is reached in a
deployment like the Fargate shape, what it refuses at the network edge before any token check,
and whether it shares tool implementations with the stdio door or only their contract.

Then decided 2026-09-27: the transport is MCP over HTTP (streamable, with server-sent events where
a stream is needed), with TLS ended by the platform's load balancer in front of the door service,
and the door refuses anything but its own MCP paths before any token check. Recorded in
[ADR 0077](../../../decisions/0077-the-network-door-speaks-http-and-takes-a-signed-short-lived-token.md).
Whether the door shares tool implementations with the stdio door or only their contract was not
asked and is left to the build.
