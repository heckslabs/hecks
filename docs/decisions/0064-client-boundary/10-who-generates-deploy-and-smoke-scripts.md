# 10: Who generates deploy and smoke scripts

**Status:** Open (wayfinder ticket) · **Type:** grilling (HITL) · **Blocked by:** 04 · **Claimed by:** unclaimed
**Map:** [0064 client boundary](../0064-client-boundary-map.md)

## Question

A client site carries about 1,900 lines of hand-written hosting tooling: a deploy script that swaps one container image and syncs the image-tag parameter, a post-deploy smoke script, per-branch preview stacks, an expected-era file, a smoke harness, and Makefile targets. All of it carries the client's constants (region, stack names, cluster, image repositories, account id, hostname, alert address, and a hardcoded absolute path to a Hecks checkout).

Decide where that tooling comes from, using the findings of ticket 04:

- **A. Hecks generates it** from the project's world file, alongside the template it already emits. The platform only records deployments (the deployment, CI run and health-check aggregates); the generated scripts call it.
- **B. The platform owns hand-written, parameterized scripts;** Hecks emits only the template.
- **C. Each client keeps its own,** with Hecks providing nothing beyond the template.

Also decide: the gate for switching a live stack to generated output (an empty CloudFormation change set is proposed), and whether the smoke harness's generic half (checks, signed cookies, safe-mode addresses, the era check) ships as a Hecks template.

## Working recommendation (not a decision)

A, as a spike first, gated on an empty change set against the live stack and regenerated beside the current files so the two can be diffed before switching.

## Decision

Not yet resolved.
