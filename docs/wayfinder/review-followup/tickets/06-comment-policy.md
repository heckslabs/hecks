---
type: grilling
status: open
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

## Answer
