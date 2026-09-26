# 10: Who generates deploy and smoke scripts

**Status:** Accepted 2026-09-26 · **Type:** grilling (HITL) · **Blocked by:** none (ticket 04 resolved) · **Claimed by:** unclaimed
**Map:** [0064 client boundary](../0064-client-boundary-map.md)

## Question

A client site carries about 1,900 lines of hand-written hosting tooling: a deploy script that swaps one container image and syncs the image-tag parameter, a post-deploy smoke script, per-branch preview stacks, an expected-era file, a smoke harness, and Makefile targets. All of it carries the client's constants (region, stack names, cluster, image repositories, account id, hostname, alert address, and a hardcoded absolute path to a Hecks checkout).

Decide where that tooling comes from, using the findings of ticket 04:

- **A. Hecks generates it** from the project's world file, alongside the template it already emits. The platform only records deployments (the deployment, CI run and health-check aggregates); the generated scripts call it.
- **B. The platform owns hand-written, parameterized scripts;** Hecks emits only the template.
- **C. Each client keeps its own,** with Hecks providing nothing beyond the template.
- **D. Hecks generates for new clients only.** The existing client keeps its hand-written stack until convergence is cheap.

**What ticket 04 found:** the generator emits one container and a fixed shape; the client's stack is multi-container with fixed logical ids, path routing, a retained CDN distribution, alarms and preview stacks. An empty change set is not reachable by tuning; it needs a generator that can pin every logical id, name and property. So option A means a large generator extension for the existing client, while a new client can adopt the generated shape from the start. That makes D a real option.

Also decide: the gate for switching a live stack to generated output (an empty CloudFormation change set is proposed), and whether the smoke harness's generic half (checks, signed cookies, safe-mode addresses, the era check) ships as a Hecks template.

## Working recommendation (not a decision)

D now, A later. Generate the scripts and a multi-container template for new clients so future clients start from the generated shape, and converge the existing client only when a spike shows an empty change set is reachable. Never execute a change set against the live stack without the owner's approval.

## Decision

Accepted by the owner on 2026-09-26: **A**. Hecks generates the template and the hosting scripts from the world block, and the platform only records deployments. The gate for switching a live stack to generated output is an empty CloudFormation change set: first compared offline by template, and executed only with the owner's explicit approval. Ticket 04 showed that this needs a generalized generator. Option D (generate for new clients only) remains the fallback if converging the existing client proves too costly.
