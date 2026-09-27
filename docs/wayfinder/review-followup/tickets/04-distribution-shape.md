---
type: grilling
status: open
blocked_by: [01-research-what-escapes-the-gem]
claimed_by:
---

# Distribution shape: what `gem install hecks` ships

## Question

Today the installed gem is far less than the repo: no executables, and dev tooling in `lib/`
reaches paths that do not exist in a gem. Decide: one `hecks` executable with subcommands
versus the current 85 `bin/` scripts; one gem versus a lean runtime gem plus a tooling gem
(`hecks-dev`); and where each group from the research ticket lands. What does an evaluator get
from `gem install`, and what stays repo-only?

## Answer
