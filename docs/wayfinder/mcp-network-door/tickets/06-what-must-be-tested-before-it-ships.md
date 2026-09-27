---
type: grilling
status: open
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
