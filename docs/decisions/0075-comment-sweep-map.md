# Map: Hecks comments that read like a mature framework

**Status:** Open map (wayfinder). Each ticket under `0075-comment-sweep/` is an ADR-shaped question. Resolving one fills in its own Decision section, sets its Status to Accepted, and adds a line to "Decisions so far" below. The map is an index: a decision lives in exactly one place, its ticket.

**Charted:** 2026-09-26. Nothing under a ticket's "Working recommendation" is decided.

## Destination

Every code comment in the repository is short, states what a thing is or why it is non-obvious, and reads like Rails API documentation rather than a design essay. The map is finished when the standard is written down, the two open mechanisms (which items are public, and how a Rust change is proven comment-only) are decided, and the sweep is sliced into an order a single draft PR can follow, so nothing is left to decide before someone starts.

## Notes

- **Skills for every session:** `grilling` and `domain-modeling` for HITL tickets. Research tickets are resolved by a research subagent.
- **Plan, do not build.** A ticket produces a decision. Rewriting comments, extending the linters and wiring CI are out of this map. A prototype ticket may rewrite a handful of files to judge the standard, and that work is thrown away.
- **Hecks stores no client names.** Every ADR under this map keeps to that, and so does any sample text a ticket quotes.
- **Claiming a ticket:** set its `Claimed by` line before doing any work, so concurrent sessions skip it. An open ticket with `Claimed by: unclaimed` is takeable when everything in its `Blocked by` line is Accepted.
- **ADR numbers:** this map is 0075. Tickets are numbered inside its folder, not in the global sequence.
- **Related, in flight:** ADR 0069 (PR 867) already decided a comment policy for `lib/hecks`: history phrases, a CI gate and a provisional block ceiling of 50 lines with a baseline, implemented in PR 874. Ticket 01 here sets stricter limits over the whole repository. How the two reconcile (whether 0075 amends 0069's ceiling and scope) is open, and any sweep lands after PR 874 and re-runs on the files it touched.
- **Prior work on main** is the standard this map replaces in part: the comment style guide and Ruby linter, the design-history and RDoc pass, and the Rust guide and linter (PRs 753, 761 and 766).

## Decisions so far

<!-- one line per Accepted ticket: [title](link) - gist of the answer -->

- [01 The comment standard](0075-comment-sweep/01-the-comment-standard.md) - Rails voice, hard length limits enforced in CI, docs required only on the public surface, history banned, everything in the repo in one draft PR that is re-runnable and proven comment-only.

## Tickets

Open, in the order they are takeable:

- [02 The public surface list](0075-comment-sweep/02-the-public-surface-list.md) - takeable now.
- [03 Proving a Rust change is comment-only](0075-comment-sweep/03-proving-a-rust-change-is-comment-only.md) - takeable now.
- [05 A pilot rewrite of a sample](0075-comment-sweep/05-a-pilot-rewrite-of-a-sample.md) - takeable now.
- [04 The sweep method and cost](0075-comment-sweep/04-the-sweep-method-and-cost.md) - blocked by 02, 03 and 05.

## Not yet specified

In scope, but not sharp enough to ticket. Each graduates when the frontier reaches it.

- **Linter rule set and allowlist format.** The exact categories, the false-positive list for the widened history phrases, and the allowlist file's shape. Hangs on tickets 01 and 05.
- **Handling the template regions** in the hand-written Rust exemplar files, whose comments are source for generated code, and the order of regenerating. Hangs on ticket 04.
- **CI wiring and run time.** Changed-files versus full-tree runs, and how much time the two linters and the equivalence check may add. Hangs on tickets 03 and 04.
- **The tagging pass mechanics** that marks internals once the public list exists. Hangs on ticket 02.
- **Landing procedure:** the merge freeze, the message to other sessions, and how a conflicting branch re-runs the sweep. Hangs on ticket 04.
- **Final ordering:** how the decided work is grouped into commits inside the one PR. Graduates last.

## Out of scope

- **Markdown prose.** Docs, ADRs, the README and the CHANGELOG are not swept. They are where prose moved out of comments belongs.
- **Other repositories.** The style is proven here first.
- **Doing the sweep.** This map decides how; the work follows it.
