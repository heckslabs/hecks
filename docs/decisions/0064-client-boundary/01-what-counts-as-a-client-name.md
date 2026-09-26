# 01: What counts as a client name, and does "zero" include shipped history?

**Status:** Accepted 2026-09-26, with one open sub-question · **Type:** grilling (HITL) · **Blocked by:** none · **Claimed by:** unclaimed
**Map:** [0064 client boundary](../0064-client-boundary-map.md)

## Question

The goal is that Hecks stores no client names. That needs a definition before anything is scrubbed.

1. **Which names count?**
   - (a) External customer projects.
   - (b) The org's own projects that appear as examples or sources in comments and fixtures.
   - (c) The org itself, where it appears only as the registry name in the `uses_embryonaut_bluebook` keyword and the `vendor/embryonaut_bluebooks/` path.
   - **What the inventory found (ticket 03):** outside the keyword and path, the org's own name appears in about 66 files: stack and deploy names, deploy templates, host auth comments, a deploy spec, and an example domain named for the org (about 340 hits, plus generated output and a corpus file). Decide whether (c) covers these, or only the registry keyword and path.
2. **Does zero include shipped history?** The CHANGELOG, released ADRs, the docs and past published gem versions mention names. Rewriting them makes the repository clean but cannot change gem versions already published.
3. **How is "zero" kept true afterwards?** A committed denylist spec would itself store the names it forbids.

## Working recommendation (not a decision)

- (a) and (b) go to zero, including ADRs, the CHANGELOG and docs, reworded to neutral wording such as "a client site" or "an external checkout".
- (c) stays: it is the org's own registry name, and the keyword rename is out of scope for the map.
- Published gem versions are left as they are.
- No committed denylist. Verify with a one-off local search at the end of the scrub and rely on review after that.

## Decision

Accepted by the owner on 2026-09-26.

- Names (a) and (b) go to zero, including ADRs, the CHANGELOG and docs, reworded to neutral wording that keeps the technical meaning.
- (c) stays: the org's name remains only as the registry name in the `uses_embryonaut_bluebook` keyword and the `vendor/embryonaut_bluebooks/` path.
- Published gem versions are left as they are.
- No committed denylist. A one-off local search at the end of the scrub proves zero hits.

**Open sub-question, found by ticket 03:** the org's own name also appears in about 66 files outside the registry keyword and path (stack names, deploy templates, a deploy spec, and an example domain named for the org). The scrub leaves these for now. The owner still has to say whether they count as "client names".
