---
type: grilling
status: open
blocked_by: []
claimed_by:
---

# MCP door auth: a caller token before any multi-agent wiring

## Question

ADR 0062 says MCP servers need real authentication before any network transport. Even over
stdio, `role` and `actor_id` are self-asserted. Decide whether stdio gets a local shared secret
or a signed caller token now, how it composes with the Governance grant check, and whether this
is a prerequisite for network transport or independent of ADR 0062.

## Answer
