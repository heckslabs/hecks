# Map: a Hecks with no client material, and a right home for each piece that leaves it

**Status:** Open map (wayfinder). Each ticket under `0064-client-boundary/` is an ADR-shaped question. Resolving one fills in its own Decision section, sets its Status to Accepted, and adds a line to "Decisions so far" below. The map is an index: a decision lives in exactly one place, its ticket.

**Charted:** 2026-09-26. Nothing under a ticket's "Working recommendation" is decided.

## Destination

Hecks holds no client names and no client product code. Generic capability that client repos carry today lives in Hecks. Org-specific pieces live in the org's own repos (the platform and the shared bluebook packages). Client-specific pieces stay in the client repo. The map is finished when every decision below is made and the resulting work is sliced into reviewable pieces in a clear order, so nothing is left to decide before someone starts.

## Notes

- **Repos involved:** Hecks (this repo), one client site repo (the only client today), the org platform repo, the org shared-bluebooks repo.
- **Skills for every session:** `grilling` and `domain-modeling` for HITL tickets. Research tickets are resolved by a research subagent.
- **Hecks stores no client names.** Every ADR under this map says "a client site", never a client's name. The same holds for the code and docs the resulting work touches.
- **Plan, do not build.** A ticket produces a decision. The work it unblocks is out of this map.
- **No deploys, rollbacks or era mints** happen under this map. Changes that alter production behavior on the next deploy are flagged in their own PRs, and the owner decides when to deploy.
- **ADR numbers:** this map is 0064. Tickets are numbered inside its folder, not in the global sequence.
- **Claiming a ticket:** set its `Claimed by` line before doing any work, so concurrent sessions skip it. An open ticket with `Claimed by: unclaimed` is takeable when everything in its `Blocked by` line is Accepted.
- **Another session owns five small Hecks PRs** (read-model refusal, PostgresEra mint refusal, two Rust codec fixes, one ADR update). They land before any change here touches `spec/corpus`, `docs/decisions` or `CHANGELOG.md`.

## Decisions so far

<!-- one line per Accepted ticket: [title](link) - gist of the answer -->

- [03 Client-name inventory](0064-client-boundary/03-client-name-inventory.md) - 100 files, about 78 prose-only and about 22 load-bearing (two generated modules, corpus values, two host runtime constants, inline test data); the org's own name is a separate 66-file cluster.
- [04 What the Fargate projection emits today](0064-client-boundary/04-what-the-fargate-projection-emits-today.md) - the generator emits one container in a fixed shape; an empty change set against the client's multi-container stack is not reachable by tuning, only by a generator that can pin every logical id, name and property.

## Tickets

**Frontier (open, unblocked, unclaimed):**

| Ticket | Type | Question in one line |
| --- | --- | --- |
| [01 What counts as a client name](0064-client-boundary/01-what-counts-as-a-client-name.md) | grilling | Which names count, and does zero include shipped history? |
| [02 Is commerce a Hecks capability](0064-client-boundary/02-is-commerce-a-hecks-capability.md) | grilling | Do payments, checkout, email, newsletter and registrations belong in the host? |
| [05 A JavaScript package for Hecks clients](0064-client-boundary/05-a-javascript-package-for-hecks-clients.md) | grilling | Does Hecks ship one, with what contents, and how is it versioned |
| [06 The npm scope](0064-client-boundary/06-the-npm-scope.md) | task | Who owns the package scope, and is it claimed |
| [07 Rate limit defaults](0064-client-boundary/07-rate-limit-defaults.md) | grilling | Should the host rate-limit public writes by default, and how is it configured |
| [08 Platform tooling that belongs in Hecks](0064-client-boundary/08-platform-tooling-that-belongs-in-hecks.md) | grilling | Which of the platform's generic pieces move, and which stay |
| [09 The live banking deploy recipe](0064-client-boundary/09-the-live-banking-deploy-recipe.md) | grilling | Where the recipe for the live example stack lives once it leaves Hecks |
| [10 Who generates deploy and smoke scripts](0064-client-boundary/10-who-generates-deploy-and-smoke-scripts.md) | grilling | Hecks for all clients, for new clients only, the platform, or each client |

**Blocked:**

| Ticket | Type | Blocked by |
| --- | --- | --- |
| [11 How to slice the client-name scrub](0064-client-boundary/11-how-to-slice-the-client-name-scrub.md) | grilling | 01 |

## Not yet specified

In scope, but not sharp enough to ticket. Each graduates when the frontier reaches it.

- **Settings the commerce code needs de-hardcoded**, and the rollout order for the one change that alters production on the next deploy. Hangs on ticket 02.
- **The seat rule and other rules duplicated between the host and the client's JavaScript.** How the host exposes them. Hangs on ticket 02.
- **What the multi-container Fargate projection should emit**, plus the era-expectation check and the generic smoke harness. Hangs on ticket 10. Ticket 04 found this means a generator that can pin every logical id, name and property, not a tuning of the current one.
- **Drift between a client's live stack and its committed template.** Ticket 04 saw that one listener rule cited in a preview template is absent from the live template; whether it is unmanaged, and whether to run drift detection, is unspecified. Hangs on ticket 10.
- **A default-database and a default-adapter world setting** to replace repeated per-chapter blocks. Hangs on ticket 10.
- **Where the deployment-recording aggregates live** (the platform repo or the shared-bluebooks repo). Hangs on ticket 10.
- **Newsletter subscriber import:** a Hecks command, a bluebook adapter, or client-only. Hangs on ticket 02.
- **A Payload adapter package:** the trigger for building one (a second site using the same CMS). Hangs on ticket 05.
- **Retiring the client's Ruby server path and its duplicate admin pages** once CI exercises the host. Hangs on ticket 02.
- **The generic snapshot reader and value-object unwrapping** in the platform's sync code. Speculative until a second consumer exists.
- **Final ordering:** how all decided work is grouped into tracks and PRs. Graduates last, after the tickets above.

## Out of scope

- **Renaming the `uses_embryonaut_bluebook` keyword and its vendor path.** It names the org's own shared package library, not a client, and renaming touches most layers of the framework for a naming preference. Ruled out on 2026-09-26. The drifting vendor scripts are in scope, only the name is not.
- **The five small Hecks PRs owned by another session.** They are a prerequisite for the scrub, not part of this map.
- **Deploys, rollbacks and era mints.**
- **Deleting leftover local branches and worktrees** from earlier agent sessions.
