# A failed verification names the first bad merge and decides nothing

**Status:** Accepted. Date: 2026-11-17. Asked for by the Work item
`post-merge-bisect-reverts-one-change`.

## Context

While the shallow check is off, a verification of local main runs the specs the landings since the
last verified commit touch. When it fails, its refusal named the failing spec but not which landing
broke it, so a red main was answered with a batch rather than a cause.

## Decision

1. **The refusal names one merge.** While the shallow check is off, a failed verification searches
   the first-parent merges between the last verified commit and the verified one
   (`MainIntegration::FirstBad`) and adds one line to its refusal: the first merge whose own specs
   fail, with the spec file and first failing example. It is a fact; the adapter reverts nothing,
   writes no marker, raises no flag and parks nothing.
2. **The search is bounded and quiet.** At most six probes, each a clean copy of one merge running
   the specs its own paths touch, one after another, after the verification's own copy is released
   so the copy's turn is free. A probe that errors, a head that moved or a spent budget gives no
   line, and the original refusal stands.
3. **The search assumes a failure stays once it appears.** When a later merge mends it, the answer
   is still the first merge that failed.
4. **Limits agreed for what acts on the line.** Revert only that one merge, never a batch; one
   revert per red episode, and a main still red after it is parked for a person; landings wait while
   main is red, red-* fixes still land. These are the domain's to enforce and are not built here.

## Consequences

The decisions in item 4 need a revert command and policies in the delivery and red-flag bluebooks,
outside the adapters. They are filed as a separate Work item.
