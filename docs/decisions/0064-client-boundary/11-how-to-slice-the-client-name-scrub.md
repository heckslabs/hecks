# 11: How to slice the client-name scrub

**Status:** Accepted 2026-09-26 · **Type:** grilling (HITL) · **Blocked by:** 01 (ticket 03 resolved) · **Claimed by:** unclaimed
**Map:** [0064 client boundary](../0064-client-boundary-map.md)

## Question

Using the definition from ticket 01 and the inventory from ticket 03, decide how the scrub is broken into reviewable pieces and ordered.

1. **Slicing:** by area (runtime code, scripts and deploy, docs and ADRs and the CHANGELOG, specs and fixtures), or by name, or as one change.
2. **Load-bearing names** (fixture identifiers, golden files, generated IR): rename and regenerate in the same piece as the change that needs them, or in a separate piece.
3. **Ordering against the five PRs another session owns,** which touch the corpus, ADRs and the CHANGELOG.
4. **Verification:** a one-off local search of `origin/main` for every name returns nothing, run at the end and not committed.
5. **Historical text:** how to reword released ADRs and CHANGELOG entries without changing what they meant.

## Working recommendation (not a decision)

Four PRs by area, branched from fresh `origin/main` after the other session's PRs merge, each regenerating what it renames. Reword history to neutral wording that keeps the technical meaning. Finish with the one-off search.

## Decision

Accepted by the owner on 2026-09-26. The scrub lands inside one long-running PR, done by parallel workers split by area (runtime code, scripts and deploy, docs and ADRs and the CHANGELOG, specs and fixtures). Anything renamed that feeds generated output is regenerated last, after the other changes are merged. History is reworded to neutral wording that keeps its technical meaning. A one-off local search of the final tree proves zero hits.
