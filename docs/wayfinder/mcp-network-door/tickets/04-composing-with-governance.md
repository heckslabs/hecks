---
type: grilling
status: open
blocked_by: [01-where-principals-live]
claimed_by:
---

# Composing with Governance

## Question

Today the door calls `Hecks.as_caller(role:, actor_id:)` (`lib/hecks/storehouse.rb`) and
`refuse_role_mismatch` (`runtime/command_rules/authorization.rb`) compares the claim to the
command's role, or to a Governance role assignment when an `actor_id` is given. Decide how a
verified principal takes the place of those two caller-supplied fields, what happens to a request
that still sends `role:` or `actor_id:` (ignored, or refused), and what the refusal says. Decide
whether the read tools, which take no role today, require a verified principal on the network
door, and whether a token can narrow a principal's roles below what Governance grants.

## Answer
