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

## Not yet specified

- The `hecks` executable's subcommand surface, once the distribution shape is decided.
- Release-channel mechanics (pre-release line, deprecation windows), once the cadence is decided.
- Which roadmap items to cut, once the adoption wedge is chosen.
- What a Rails integration would have to look like, if the wedge is Rails.
- Whether to renumber the seven duplicate ADR pairs, once the decisions above settle which ADRs get rewritten anyway.

## Out of scope

- Any implementation. Each decided "do" becomes its own build session.
- Renumbering or merging the client-boundary work already in flight (PR #860); this map only sequences around it.
