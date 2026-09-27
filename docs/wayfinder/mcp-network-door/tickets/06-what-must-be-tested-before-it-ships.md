---
type: grilling
status: closed
blocked_by: []
claimed_by:
---

# What must be tested before it ships

## Question

ADR 0062 requires forged-token specs. Decide the minimum set a network door needs before anyone
can reach it: a forged signature, an expired token, a revoked token, a token for another audience,
a request that still carries a self-asserted `role:` or `actor_id:`, and a path the door should
never route. Decide whether these run against a real network listener as well as in-process,
whether the network door joins the existing MCP subprocess specs, and what a failing check blocks
(the door's own release, or every release).

## Answer

Decided 2026-09-27: the full set, on a real listener. A forged signature, an expired token, a token
for another audience, a revoked token, a request still carrying `role:` or `actor_id:`, and a path
the door never routes; each runs in-process and against a real listener, and the cases join the MCP
subprocess specs. A failing one blocks the door's own release, and not the gem's. Recorded in
[ADR 0077](../../../decisions/0077-the-network-door-speaks-http-and-takes-a-signed-short-lived-token.md).
