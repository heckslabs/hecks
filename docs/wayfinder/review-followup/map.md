---
label: wayfinder:map
---

# Review follow-up: the way from an outside review to a decided plan

## Destination

A decided, sequenced plan. Every item from the 2026-09-26 outside review has a recorded
decision (do, defer, or reject), an order, and a size, so each "do" can be handed to its own
build session. Nothing here builds; each resolved ticket lands as an ADR in `docs/decisions/`.

## Notes

- Tracker: local markdown. A ticket is a file under `tickets/`; front matter carries `type`,
  `status` (`open` or `closed`), `blocked_by`, and `claimed_by`. A ticket is on the frontier
  when it is open, unclaimed, and every ticket in `blocked_by` is closed.
- A resolved decision is written as an ADR (take the next free number; duplicates are linted
  by `spec/adr_numbers_unique_spec.rb`, PR #863). The ticket's `## Answer` gists it and links it.
- Docs rules apply to everything here: no client names, no spec counts, comments follow
  `docs/COMMENT_STYLE_GUIDE.md`.
- Source of the items: an outside read of the repo. Its claims were spot-checked locally and
  most held (gemspec ships `lib/**` only, about 55% of `lib/` lines are comments, duplicate ADR
  numbers). Prep found three that did not: `group_by` drops rows on every adapter, not only
  memory; both runtimes already accept a bare scalar for a single-field value object, so the
  *Value-object ergonomics* premise is stale; and the commit rate is about 14 a day over the
  last 30 days, not 25.
- Every open decision ticket carries a `## Prep (not a decision)` section: cited facts, options
  and a recommendation gathered read-only for the grilling session. Prep is input. A ticket
  closes only when the maintainer decides and the answer is recorded.

## Decisions so far

<!-- one line per closed ticket: [title](tickets/NN-slug.md) — gist -->

- [Research: what in `lib/` reaches outside an installed gem](tickets/01-research-what-escapes-the-gem.md) — dev tooling (fuzzing, bench, corpus, codemod, grammar evolve) is a clean seam, but two runtime paths (syntax-boot cache, Storehouse log) write into the gem directory today.
- [Research: are the two silent-wrong bugs still live on main](tickets/02-research-silent-wrong-status.md) — both reproduce; `group_by` drops rows on every adapter, not just memory; both refuse only under the opt-in `--profile client`, nothing by default.
- [Silent-wrong bugs](tickets/03-silent-wrong-bugs.md) — fix the dotted `compute` SQL, refuse a colliding `group_by` on both runtimes with a seal-time stopgap, correct the README first. [ADR 0065](../../decisions/0065-silent-wrong-constructs-are-refused-or-fixed.md).
- [Distribution shape](tickets/04-distribution-shape.md) — stop writing into the gem dir, then ship `exe/hecks` over the operator scripts; dev tooling stays repo-only. [ADR 0066](../../decisions/0066-the-gem-ships-a-hecks-executable-and-dev-tooling-stays-in-the-repo.md).
- [Release cadence](tickets/05-release-cadence.md) — keep the pace, state a two-tier promise, pin deploys exactly; fix the missing tag, date and Releases page. [ADR 0068](../../decisions/0068-releases-keep-their-pace-and-state-a-two-tier-promise.md).
- [Comment policy](tickets/06-comment-policy.md) — history phrases, then a CI gate, then a `long_block` ceiling with a baseline. [ADR 0069](../../decisions/0069-the-comment-linter-becomes-a-ci-gate-and-bounds-block-length.md).
- [Doc hygiene](tickets/07-doc-hygiene.md) — banner and stale-version specs; `docs/archive/` takes the survey and the adoption audit. [ADR 0070](../../decisions/0070-docs-carry-dated-snapshot-banners-and-a-stale-version-guard.md).
- [Newcomer path](tickets/08-newcomer-path.md) — Memory-default console, short README with glossary, guides doctested. [ADR 0073](../../decisions/0073-the-newcomer-path-is-a-memory-default-console-and-a-short-readme.md).
- [Value-object ergonomics](tickets/09-value-object-coercion.md) — already shipped; confirm live, sweep docs, pin with a cross-runtime fixture. [ADR 0067](../../decisions/0067-a-single-attribute-value-object-takes-a-bare-scalar.md).
- [Adoption wedge](tickets/10-adoption-wedge.md) — a standalone rules service first; Rails a fast-follow. [ADR 0071](../../decisions/0071-the-first-external-target-is-a-standalone-rules-service.md).
- [MCP door auth](tickets/11-mcp-door-auth.md) — no token now; a per-tool allowlist if multi-agent use is near. [ADR 0072](../../decisions/0072-the-mcp-door-token-waits-for-a-real-need-and-a-tool-allowlist-comes-first.md).
- [Agent review gates](tickets/12-agent-review-gates.md) — the maintainer's own account, stated beside what CI and GitHub prove. [ADR 0074](../../decisions/0074-contributing-states-how-changes-are-built-reviewed-and-what-ci-proves.md).

## Proposed build order

Every ticket is decided. This order is a proposal for the maintainer to adjust; sizes are the
prep's own estimates. Each item is its own build session and PR.

1. **Small and mechanical (S).** Merge the ADR-number lint (#863); README wording fix for
   `group_by` and the dotted-compute caveat ([ADR 0065](../../decisions/0065-silent-wrong-constructs-are-refused-or-fixed.md));
   the `v2.5.0` tag, the `2.0.0` CHANGELOG date and the Releases page, then the two-tier
   promise text in `docs/1.0-readiness.md` ([ADR 0068](../../decisions/0068-releases-keep-their-pace-and-state-a-two-tier-promise.md));
   the live bare-scalar confirmation, docs sweep and cross-runtime fixture ([ADR 0067](../../decisions/0067-a-single-attribute-value-object-takes-a-bare-scalar.md));
   the `CONTRIBUTING.md` section ([ADR 0074](../../decisions/0074-contributing-states-how-changes-are-built-reviewed-and-what-ci-proves.md)).
2. **Correctness (S to M).** The dotted-`compute` SQL fix; then the default seal-time
   non-identity `group_by` check; then the runtime refusal on both runtimes (6 to 8 files).
3. **Guards (S to M).** The doc banner and stale-version specs and the move to `docs/archive/`,
   after #863 merges ([ADR 0070](../../decisions/0070-docs-carry-dated-snapshot-banners-and-a-stale-version-guard.md));
   the comment history-phrase cleanup, then the CI gate and `long_block` with a baseline, once
   in-flight PRs that touch `lib/` have landed ([ADR 0069](../../decisions/0069-the-comment-linter-becomes-a-ci-gate-and-bounds-block-length.md)).
4. **Distribution (S, then M).** Move the two gem-dir writes; then `exe/hecks`, the gemspec
   trim and the lazy corpus require ([ADR 0066](../../decisions/0066-the-gem-ships-a-hecks-executable-and-dev-tooling-stays-in-the-repo.md)).
5. **Newcomer path (M),** after distribution: the Memory-default console, the README rewrite and
   `getting-started.md` ([ADR 0073](../../decisions/0073-the-newcomer-path-is-a-memory-default-console-and-a-short-readme.md)).
6. **Adoption target (M),** after the correctness fixes and distribution: the documented deploy
   path and operator auth recipe, then find the outside team ([ADR 0071](../../decisions/0071-the-first-external-target-is-a-standalone-rules-service.md)).
7. **Only when triggered.** The MCP per-tool allowlist when multi-agent use is near, and the
   token design when a network door is ([ADR 0072](../../decisions/0072-the-mcp-door-token-waits-for-a-real-need-and-a-tool-allowlist-comes-first.md)).

## Not yet specified

- Whether the UL, onboarding, ISO traceability and OIDC-provider work is cut outright rather than deferred, after the adoption exit test.
- Release-channel mechanics (a pre-release line, longer deprecation windows), when a first outside adopter appears.
- What a Rails integration would have to look like, after one outsider has run a standalone service.
- Whether to renumber the seven duplicate ADR pairs; the ADR-number lint only freezes them.
- The open items each decided ADR carries (for example the `long_block` threshold, the banner wording, who the persistent agent identity is), which the build sessions or the maintainer settle.

## Out of scope

- Any implementation. Each decided "do" becomes its own build session.
- Renumbering or merging the client-boundary work already in flight (PR #860); this map only sequences around it.
