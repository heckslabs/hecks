---
type: grilling
status: open
blocked_by: []
claimed_by:
---

# Doc hygiene: staleness checks and where superseded docs go

## Question

Docs drift: a dated audit read as current, a survey doc that uses "hecks" for the predecessor
project, a 2,500-line implementation plan of mostly-unbuilt scope. Decide the mechanical guards
(a stale-version check across `docs/`, an archive folder and its rule, a marker convention for
dated snapshots such as the banner added in PR #863) and which existing docs move. Keep the
guards to what a check can prove.

## Prep (not a decision)

Gathered by a read-only agent for the grilling session; the options and recommendation are
input, not the decision.

**Facts**
- `docs/` has 19 top-level markdown files; only 5 carry a status or date banner. The most
  likely stale: `adoption-readiness.md` (dated audit; banner is in PR #863), the 2,591-line
  implementation plan (later phases still read "New" or "Research"), the survey doc (uses
  "hecks" for the predecessor project), and `future-features.md` (cites the plan as "2,511
  lines"). Several plan documents are undated.
- A grep for `VERSION =`, `\d+ commits`, `currently \d+\.\d+\.\d+` and `hecks \d+\.\d+\.\d+`
  over `docs/` (minus `decisions/`, `audits/`, `wayfinder/`) returns six hits with a very low
  false-positive rate, including a live stale version: `implemented/guides/getting-started.md:18`
  says "currently 1.0.2".
- Existing guards cover only three files: `status_docs_links_spec` (links),
  `status_docs_no_spec_counts_spec` (counts), and `readme_version_spec` (README version), plus
  `UNGATED_STATUS_DOCS` in `spec/support/doctest_names.rb`, which fails only when a new
  `docs/*.md` is added without being listed. Missing: a dated-snapshot marker check, a
  stale-version scan of `docs/`, and link checking outside those three files.
- `docs/implemented/` holds shipped work and is the wrong home for the plan, the survey or an
  audit. `docs/audits/` is the de facto dated-record folder. No archive folder exists.
- Moving is cheap. The plan is a real markdown link only from the README and CONTRIBUTING
  (both link-checked); every other reference is plain text or a code comment, and one Rust
  comment cites plan line numbers. The survey is referenced by one script, one lib file,
  `docs/tools.md` (generated from `bin/` headers) and a few docs. A move also removes the
  allow-list entries in `doctest_names.rb`.

**Options**
1. Banner-only: add banners plus a spec requiring a banner or date line in the first lines of
   each listed doc. Cheapest, no link risk; the long plan still looks current.
2. Stale-version scan, no moves: a spec over `docs/**` with a small allow-list for
   banner-marked snapshots. Would flag `getting-started.md:18` today; does not fix the plan or
   survey.
3. Add `docs/archive/`, move the plan, survey and adoption-readiness there, leave stubs. About
   10 files touched; code comments still cite them and the Rust comment's line numbers drift.
4. Options 1 and 2 together, then move only the survey and adoption-readiness; keep the plan in
   place with a banner because the README links it as the roadmap.

**Recommendation from prep.** Option 4, with an archive rule of "dated snapshot, never edited,
banner required, not linked as current", and the survey's own wording corrected in the same
pass.

**For the maintainer**
1. Is the plan a live roadmap (stays, bannered) or a historical record (moves)?
2. New `docs/archive/` beside `docs/implemented/`, or use `docs/audits/`?
3. Rename the survey to say "sibling project", or keep its filename?
4. Should the banner spec also cover `audits/` and `prds/`?
5. Should `getting-started.md:18` drop the version number, matching the no-counts stance?

## Answer
