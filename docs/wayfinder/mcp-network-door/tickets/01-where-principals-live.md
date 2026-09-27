---
type: grilling
status: open
blocked_by: []
claimed_by:
---

# Where principals live

## Question

A verified token names a principal, and Governance looks up that principal's roles. Do principals
live in each domain's own Governance (a role assignment per domain, as `actor_id` works today),
or in one identity provider that every domain and door trusts? Consider who creates and removes a
principal, what happens when one caller works across several domains, and what a door does when it
serves a domain whose Governance has never heard of the principal. This is the open question in
ADR 0062 that everything else here waits on.

## Answer
