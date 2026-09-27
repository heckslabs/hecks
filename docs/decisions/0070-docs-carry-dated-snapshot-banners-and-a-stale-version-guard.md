# Docs that are dated snapshots say so in a banner, an archive holds the ones that should not be read as current, and a scan catches stale versions

**Status:** Accepted — not yet implemented (2026-09-27). Nothing below is built. PR #863 (open) adds a "Historical snapshot" banner to `docs/adoption-readiness.md`; the move in decision 3 happens after it merges.

## Context

Docs drift, and nothing checks the drift that a machine could check. The existing guards cover three files: `spec/status_docs_links_spec.rb` (links), `spec/status_docs_no_spec_counts_spec.rb` (counts) and `spec/readme_version_spec.rb` (the README version). `UNGATED_STATUS_DOCS` (`spec/support/doctest_names.rb:73-93`) fails only when a new top-level `docs/*.md` is added without being listed, so it records that a doc is exempt from the doctest gates and says nothing about whether the doc is current. No spec requires a dated-snapshot marker, and none scans `docs/` for a version or a commit count that has gone stale.

The cost is visible today.

- `docs/implemented/guides/getting-started.md:18` says "currently 1.0.2", a live stale version.
- `docs/HECKS_IMPLEMENTATION_PLAN.md` is 2,591 lines, and the ticket that gathered these facts (`docs/wayfinder/review-followup/tickets/07-doc-hygiene.md`) reports later phases still reading "New" or "Research". `README.md:739` and `CONTRIBUTING.md:205` both link it, as the roadmap.
- `docs/adoption-readiness.md` is a dated audit written against a branch (`docs/adoption-readiness-audit`) and reads as current until the PR #863 banner merges.
- `docs/hecks-survey-what-we-wish-we-had.md` is a 2026-08-17 read of "the older, larger sibling", and it calls that sibling "hecks", the same word this project uses for itself, so a reader cannot tell which project a sentence is about.

No archive folder exists. `docs/audits/` is the de facto home for dated records and `docs/implemented/` holds shipped work, so neither is right for a survey or a plan.

## Decision

1. **Require a dated-snapshot marker on the listed docs.** A new spec requires a status or date banner in the first lines of each top-level `docs/*.md` listed in `UNGATED_STATUS_DOCS`. The number of lines and the marker wording are open items.
2. **Scan `docs/**` for stale versions.** A new spec, excluding `docs/audits`, `docs/decisions` and `docs/wayfinder`, flags `VERSION =`, `\d+ commits`, `currently \d+\.\d+\.\d+` and `hecks \d+\.\d+\.\d+`, with a small allow-list for banner-marked snapshots. It would flag `getting-started.md:18` today.
3. **Create `docs/archive/` with one rule: a dated snapshot, never edited, banner required, not linked as current.** Move `docs/hecks-survey-what-we-wish-we-had.md` and `docs/adoption-readiness.md` into it, and remove their entries from `UNGATED_STATUS_DOCS` (`spec/support/doctest_names.rb:82` and `:86`). `docs/HECKS_IMPLEMENTATION_PLAN.md` stays in `docs/` with a banner, because the README and CONTRIBUTING link it as the roadmap.
4. **The move updates what points at the moved files.** The plan is not moved, so `README.md:739` and `CONTRIBUTING.md:205` are unchanged. The survey is referenced as plain text from `bin/hecks_mcp_door:4`, `lib/hecks/storehouse.rb:11` and `:93`, `docs/tools.md:25`, `docs/future-features.md:31` and `docs/audits/2026-08-26-open-bugs-catalog.md:17`. `docs/tools.md` is generated from the `bin/` headers, so it is regenerated, not hand-edited.
5. **Fix the survey's own wording** so the predecessor project is named as the sibling project, not as "hecks".
6. **Fix `docs/implemented/guides/getting-started.md:18`.** Whether to drop the version or update it is an open item.

## Consequences

- A dated audit or survey can no longer look current: it is either bannered in place or in the archive, and a new listed doc without a marker fails the suite.
- A version, commit count or `VERSION =` string in a guide fails the suite until it is removed or the doc is banner-marked.
- The archive rule is only as strong as its spec. "Never edited" and "not linked as current" are conventions until someone writes a check for them.
- The plan keeps looking large and partly unbuilt; the banner is what tells a reader so.
- The moves touch about ten files, and the survey's cross-references in code comments change path but not meaning.

## Alternatives considered

- **Banner-only.** A banner plus the marker spec. Cheapest, no link risk, and it does not catch `getting-started.md:18` or any other stale version outside the listed docs.
- **Stale-version scan only, no moves.** Catches the live stale version and needs no link edits. It leaves the survey misleading and gives dated snapshots no home.
- **Move all three, including the plan, leaving stubs.** Removes the largest stale-looking file from `docs/`. The plan is linked as the roadmap from the README and CONTRIBUTING, so a move would either break those links or make the archive rule ("not linked as current") false on day one.

## Open items

- How many lines from the top count as "the first lines", and what wording counts as a marker.
- Whether the banner spec also covers `docs/audits` and `docs/prds`, which the stale-version scan excludes or does not mention.
- Whether `getting-started.md:18` drops the version number, in line with `spec/status_docs_no_spec_counts_spec.rb`, or updates it.
- Whether the survey keeps its filename after the move or is renamed to say "sibling project".
- What the allow-list for banner-marked snapshots contains, and who adds to it.
