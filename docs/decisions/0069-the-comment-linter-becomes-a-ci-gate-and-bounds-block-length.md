# The comment linter becomes a CI gate, and it bounds block length against a baseline

**Status:** Accepted — not yet implemented (2026-09-27). Nothing below is built. This ADR records the maintainer's answer to `docs/wayfinder/review-followup/tickets/06-comment-policy.md` and the order in which the work happens.

## Context

`CLAUDE.md:3-16` requires comments to match `docs/COMMENT_STYLE_GUIDE.md`: no design history, comment lines under 100 characters, no all-caps lead-ins. `CLAUDE.md:15-16` asks for a `bin/standardize_comments --check <path>` run before comment work is called done. Nothing makes that run. The guide says "Nothing enforces this in CI" (`docs/COMMENT_STYLE_GUIDE.md:6`), the linter's header says "This script is not a CI gate" (`bin/standardize_comments:20`), and no file under `.github/workflows/` mentions it.

The ticket's prep measured the result over `lib/**/*.rb`. These numbers come from the ticket and were not re-measured for this ADR.

- 48,048 of 88,100 lines are comment lines, 54.5%.
- 325 of 4,702 comment blocks exceed 25 lines, and 53 exceed 50.
- 247 comment lines cite an ADR, so the volume comes from inline rationale, not from citations.
- The linter reports 171 violations in 17 of 386 files under `lib/hecks`, 138 of them all-caps.
- The linter's history list finds no history phrasing, because it does not list "no longer" (56 lines), "any more" (17) or "anymore" (5). About 78 lines need a human read, since some are legitimate present-tense statements.

The linter has no rule on block length. `LONG_CLASS_DOC = 25` (`bin/standardize_comments:32`, used at line 676) only demands `##` section headers in a long class comment. `HISTORY` (`bin/standardize_comments:116`) is the list of history phrases. `yard` is in no Gemfile, gemspec or workflow, and `lib/hecks/doc/reference.rb` builds reference docs from `bin/` headers, so no generator reads `lib/` comments today.

## Decision

Four steps, in this order.

1. **Extend `HISTORY`** in `bin/standardize_comments` with "no longer", "any more" and "anymore", then rewrite the roughly 78 flagged lines by a human read. A line that is a legitimate present-tense statement is reworded so it no longer matches, and is not left flagged.
2. **Clear the 171 existing violations with the linter's `--fix`, then run `bin/standardize_comments --check` in CI as a gate.** Correct the two statements that say the opposite: `docs/COMMENT_STYLE_GUIDE.md:6` and `bin/standardize_comments:20`.
3. **Add a `long_block` rule** to the linter, with a checked-in baseline file listing the existing offenders. Only a new or grown block fails.
4. **Trim old blocks opportunistically,** in the same PR that already touches the file.

There is no ADR-migration campaign now.

## Consequences

- A comment that breaks the guide fails CI instead of relying on the author to remember `CLAUDE.md:15`.
- The 55% comment share is held where it is, not reduced, until old blocks are trimmed one file at a time. Existing long blocks are tolerated through the baseline.
- The baseline file is a second thing to maintain: a trimmed block should leave it, and a legitimately longer block needs a deliberate baseline change that a reviewer sees.
- Step 1 touches about 78 lines and step 2 touches 17 files, all under `lib/hecks` per the ticket. Open PRs touched nothing under `lib/` when the ticket was written, so no collision was expected; later feature PRs on the heaviest files are the risk.
- The guide's per-method YARD tags stay, since trimming does not depend on any generator.

## Alternatives considered

- **An ADR-migration campaign for the 53 blocks over 50 lines.** It shrinks the total and puts the rationale in one place. It is large, it conflicts with feature PRs, and it needs a call on which rationale is ADR-worthy. Not chosen now.
- **Extend the history phrases only** (step 1 alone). Small and mechanical, and it does nothing about the share, or about the guide being unenforced.
- **No change.** The guide stays advisory, and the 171 violations and the history phrasing stay where they are.

## Open items

- What is the `long_block` threshold? The linter already uses 25 for `##` headers. The prep floated 40 and 50; neither is chosen.
- Is a 55% comment share a defect, or acceptable because agents read this code and want the rationale inline? The answer decides whether the rule only stops growth or later sets a ceiling.
- Which files does the CI gate cover: `lib/hecks` only, where the 171 were counted, or also `bin/`, `spec/` and `examples/`, which `CLAUDE.md:3` names?
- Where does the baseline file live, and does it record a block by file and starting line, or by a fingerprint that survives edits above it? "Grown" needs a definition.
- Will `yard` or API docs ever be published? If so the per-method tags become a build input and the gate could check them.
- Where does rationale live when a block is trimmed: an ADR per block, `docs/`, or nowhere?
