# Map: a Hecks with no client material, and a right home for each piece that leaves it

**Status:** Executed (wayfinder). Every ticket under `0064-client-boundary/` is Accepted or Resolved, the work they decided shipped in Hecks 2.7.0, and the client site runs it in production. The map is an index: a decision lives in exactly one place, its ticket. "Shipped" and "Follow-ups" below record what is done and what is left.

**Charted:** 2026-09-26. **Executed:** 2026-09-27.

## Destination

Hecks holds no client names and no client product code. Generic capability that client repos carry today lives in Hecks. Org-specific pieces live in the org's own repos (the platform and the shared bluebook packages). Client-specific pieces stay in the client repo. The map is finished when every decision below is made and the resulting work is sliced into reviewable pieces in a clear order, so nothing is left to decide before someone starts.

## Notes

- **Repos involved:** Hecks (this repo), one client site repo (the only client today), the org platform repo, the org shared-bluebooks repo.
- **Skills for every session:** `grilling` and `domain-modeling` for HITL tickets. Research tickets are resolved by a research subagent.
- **Hecks stores no client names.** Every ADR under this map says "a client site", never a client's name. The same holds for the code and docs the resulting work touches.
- **Plan, do not build.** A ticket produces a decision. The work it unblocks is out of this map.
- **The map made no era mints.** Changes that alter production behavior on the next deploy were flagged in their own PRs, and the owner chose when to deploy.
- **ADR numbers:** this map is 0064. Tickets are numbered inside its folder, not in the global sequence.
- **Claiming a ticket:** set its `Claimed by` line before doing any work, so concurrent sessions skip it. An open ticket with `Claimed by: unclaimed` is takeable when everything in its `Blocked by` line is Accepted.

## Decisions so far

<!-- one line per Accepted ticket: [title](link) - gist of the answer -->

- [03 Client-name inventory](0064-client-boundary/03-client-name-inventory.md) - 100 files, about 78 prose-only and about 22 load-bearing (two generated modules, corpus values, two host runtime constants, inline test data); the org's own name is a separate 66-file cluster.
- [04 What the Fargate projection emits today](0064-client-boundary/04-what-the-fargate-projection-emits-today.md) - the generator emits one container in a fixed shape; an empty change set against the client's multi-container stack is not reachable by tuning, only by a generator that can pin every logical id, name and property.
- [01 What counts as a client name](0064-client-boundary/01-what-counts-as-a-client-name.md) - external customer projects and the org's own example projects go to zero, including ADRs and the CHANGELOG; the org name stays only as the registry keyword and path; no committed denylist. One sub-question is open (the org's own name in stack names and the example domain).
- [02 Is commerce a Hecks capability](0064-client-boundary/02-is-commerce-a-hecks-capability.md) - yes, generalized in place: no crate split, hardcoded names and settings fixed.
- [05 A JavaScript package for Hecks clients](0064-client-boundary/05-a-javascript-package-for-hecks-clients.md) - built now in this repository as `packages/hecks-client`, versioned with the gem; publishing waits on ticket 06.
- [07 Rate limit defaults](0064-client-boundary/07-rate-limit-defaults.md) - on by default for public writes, settings named for the concept; a deployment behind a proxy must set the trusted-proxy settings.
- [08 Platform tooling that belongs in Hecks](0064-client-boundary/08-platform-tooling-that-belongs-in-hecks.md) - the gem-pin check, the schema dump proof and the boot fix move; handoff packaging stays in the platform.
- [09 The live banking deploy recipe](0064-client-boundary/09-the-live-banking-deploy-recipe.md) - the stack stays; its recipe moves to the platform repo after a byte-identical regeneration, and Hecks keeps a neutral example.
- [10 Who generates deploy and smoke scripts](0064-client-boundary/10-who-generates-deploy-and-smoke-scripts.md) - Hecks generates them from the world block, gated by an empty change set; generating for new clients only is the fallback.
- [11 How to slice the client-name scrub](0064-client-boundary/11-how-to-slice-the-client-name-scrub.md) - one PR, parallel workers by area, generated output regenerated last.
- [06 The npm scope](0064-client-boundary/06-the-npm-scope.md) - the free `hecks` organization was created on npm, so the package is `@hecks/client`. It was published with 2.7.0, and later releases publish from CI through npm trusted publishing, so the account keeps its passkey two-factor.


## Tickets

No ticket is open. Every ticket is Accepted or Resolved and indexed under "Decisions so far". Ticket 01 still carries one open sub-question about the org's own name outside the registry keyword; it is listed under "Follow-ups".

## Shipped

Work the decisions above produced, all on `main` and released as Hecks 2.7.0 (2026-09-27), and running in production for the one client site.

- **Host:** the per-address rate limiter, on by default; the payments secret id and webhook description as settings, with the secret id required on AWS; the public seat reads `GET /events/seats` and `GET /events/<slug>/seats`.
- **`@hecks/client`:** `packages/hecks-client`, published to npm as `@hecks/client` 2.7.0. CI publishes it through npm trusted publishing (`publish-client.yml`), and `bin/release` cuts the gem and the package together.
- **Tooling moved in from the platform:** `Hecks::Vendoring` and `bin/vendor_bluebook`, `Hecks::Release::GemPin`, `PostgresDump`, and the era plugin loading itself on boot.
- **Deploy layer:** the multi-container Fargate projection, `bin/deploy_template_diff`, `bin/check_era`, the generic smoke harness and `bin/smoke_http`, preview stacks, `bin/shape` in directory mode, and the `default_database` and `default_adapter` world settings.
- **Client names:** removed from code, comments, docs, ADRs and fixtures, with no committed denylist.
- **Other repos:** the live banking deploy recipe now lives in the platform repo, with a neutral example left here. The newsletter subscriber import and the deployment-recording aggregates (the `operations` package) live in the shared bluebooks repo. The client site dropped its Ruby server path and runs Hecks 2.7.0.

## Follow-ups

Not decided by this map, and none of them blocks anything.

- **The client's stack template is still hand-authored.** The projection and the diff tool exist, but the client deploys from its own template. Switching it to a generated one, and running drift detection between the live stack and the committed template, are open. One listener rule cited in a preview template is absent from the live template.
- **The client still carries its own JavaScript rate limiter** on the register, subscribe and contact routes beside the host's, and its own admin pages for payments and users that duplicate the host's.
- **A Payload adapter package.** Built when a second site uses the same CMS.
- **The generic snapshot reader and value-object unwrapping** in the platform's sync code. Speculative until a second consumer exists.
- **Ticket 01's open sub-question:** the org's own name in stack names and the example domain.
- **The platform cleanup**, which replaces its copies of the vendor script, `HecksPin`, `DataDump` and the `for_site` probe with the versions Hecks now ships. It is open as a draft PR in the platform repo. Its second vendor script, which exports a different repository's `web/` tree, stays because Hecks' vendoring takes only the top-level files of one directory.
- **Publishing is allowed by plain `npm publish`** from the trusted workflow. Staged-only publishing is stricter and would need a workflow change.

## Out of scope

- **Renaming the `uses_embryonaut_bluebook` keyword and its vendor path.** It names the org's own shared package library, not a client, and renaming touches most layers of the framework for a naming preference. Ruled out on 2026-09-26. The drifting vendor scripts were in scope, only the name is not.
- **Deleting leftover local branches and worktrees** from earlier agent sessions.
