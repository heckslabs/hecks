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

## Answer
