---
type: grilling
status: closed
blocked_by: []
claimed_by:
---

# Comment policy: how much "why" lives in the code

## Question

About 55% of `lib/` lines are comments, many paragraph-length and cross-referencing ADRs, some
still carrying change history despite CLAUDE.md forbidding it. Decide the target: a line-count
or density ceiling, where the "why" lives instead (ADRs, docs), whether the existing comment
linter enforces the ceiling, and how the trim is sequenced so it does not collide with in-flight
PRs that touch the same files.

## Prep (not a decision)

Gathered by a read-only agent for the grilling session; the options and recommendation are
input, not the decision.

**Facts**
- The rule today: `CLAUDE.md` requires `docs/COMMENT_STYLE_GUIDE.md` (comment lines under 100
  characters, no design history). The guide says nothing enforces it in CI, and no workflow runs
  `bin/standardize_comments`; the linter's own header says "not a CI gate".
- The linter checks YARD tags, all-caps, bare constants, design history and `long_line`. It has
  no cap on block length or density (`LONG_CLASS_DOC = 25` only demands `##` headers). Today's
  report over `lib/hecks` shows 171 violations in 17 of 386 files, 138 of them all-caps.
- Measured over `lib/**/*.rb`: 48,048 of 88,100 lines are comment lines (54.5%), 59.1% of
  non-blank lines. Directories run from about 39% (`bench`) through 47-58% for most, to 58.6%
  in `query_specification`; `router` is the outlier at 18.8%. Heaviest files by share include
  `projector/target.rb` (82%), `fuzzing/rotation_priority.rb` (80%) and
  `facade/json_door.rb` (80%). The longest blocks are `bluebook/dsl/generic_dispatch.rb:6`
  (118 lines) and `bluebook/dsl/word_gate.rb:5` (87). 325 of 4,702 blocks exceed 25 lines, 53
  exceed 50.
- ADR citations are not what drives the volume: 247 comment lines cite an ADR, about 0.5% of
  comment lines. Inline rationale is.
- History phrasing: the linter's list finds 0. The phrases it does not list, "no longer" (56
  lines), "any more" (17) and "anymore" (5), are about 78 lines needing a human read; some are
  legitimate present-tense statements.
- Open PRs touch nothing under `lib/`, so there is no collision today; the risk is later
  feature PRs on the heaviest files.
- YARD: `.yardopts` exists, but `yard` is in no Gemfile, gemspec or workflow, and
  `lib/hecks/doc/reference.rb` builds docs from `bin/` headers, not `lib/` comments. Trimming
  breaks no generator today, though the guide's per-method tags must be kept.

**Options**
- A. A density or block-length ceiling in the linter (for example a `long_block` category), with
  a checked-in baseline so only new or grown blocks fail. The linter must also be wired into CI.
- B. An ADR-migration campaign for the 53 blocks over 50 lines. Actually shrinks the total and
  puts the "why" in one place, but it is large, conflicts with feature PRs, and needs a call on
  which rationale is ADR-worthy.
- C. Extend the history-phrase list to "no longer", "any more" and "anymore" and rewrite the
  flagged lines. Small and mechanical; does nothing about the share.
- D. No change.

**Recommendation from prep.** C now, then wire `bin/standardize_comments --check` into CI
after clearing the 171 existing violations, then A with a baseline, and trim old blocks
opportunistically when a file is touched. Defer B until the maintainer says which rationale is
ADR-worthy.

**For the maintainer**
1. Is a 55% comment share a defect, or acceptable because agents read this code and want the
   rationale inline? That decides whether A sets a ceiling or only stops growth.
2. Is a CI gate on the comment linter acceptable, given the guide currently says the opposite?
3. What ceiling and baseline? The 25-line threshold exists; 40 or 50 would be new.
4. Do you plan to run `yard` or publish API docs?
5. Where should moved rationale live: an ADR per block, `docs/`, or nowhere?

## Answer

Decided 2026-09-27: accept the prep plan. Extend the history-phrase list and rewrite the flagged
lines; clear the existing linter violations and wire `bin/standardize_comments --check` into CI;
add a `long_block` rule with a checked-in baseline so only new or grown blocks fail; trim old
blocks when a file is touched. No ADR-migration campaign now. The block-length threshold is
still open. Recorded in
[ADR 0069](../../../decisions/0069-the-comment-linter-becomes-a-ci-gate-and-bounds-block-length.md).
