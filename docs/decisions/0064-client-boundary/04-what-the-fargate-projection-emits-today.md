# 04: What the Fargate projection emits today

**Status:** Open (wayfinder ticket) · **Type:** research (AFK) · **Blocked by:** none · **Claimed by:** unclaimed
**Map:** [0064 client boundary](../0064-client-boundary-map.md)

## Question

Before deciding who generates a client's deploy and smoke tooling (ticket 10), establish the gap between what Hecks generates and what a client site actually runs.

- **Read** `lib/hecks/projections/deploy/fargate.rb`, `shared.rb`, `bin/project_deploy` and the `.world` deploy block grammar, and what a generated deploy directory contains.
- **Compare** it with the client site's hand-written stack: a multi-container service (website, CMS, domain), load balancer, CDN, alarms, a domain image built with the compiled wasm and IR as sidecars, per-branch preview stacks, and the deploy, smoke and expected-era scripts.
- **Report** what is emitted today, what is missing, the parameters the missing parts would need from a `.world` block (region, owner stack, database stack, prefix, service list, image repositories, smoke workflow file, session cookie name), and where the generator's structure would have to grow.
- **Assess feasibility** of generating the client's current stack such that a CloudFormation change set against the live stack is empty. Describe how to check it. Reading existing stacks is fine; creating or executing a change set is not without the owner's approval.

Findings go on a throwaway `research/fargate-projection-gap` branch, with the pointer added below.

## Findings

Not yet run.

## Decision

Not applicable. A research ticket is resolved when its findings are recorded and the tickets that wait on it are unblocked.
