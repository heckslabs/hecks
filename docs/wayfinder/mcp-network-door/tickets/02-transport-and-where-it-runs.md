---
type: grilling
status: open
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
