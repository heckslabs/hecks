# An attach is an implied conformist relationship

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-28.

## Context

ADR 0135 has a context map written first and held against the wiring. The maps drafted for
Banking, the Hecks domain and two applications showed that most of their lines say what an
`attaches` already says: Governance is a conformist upstream of nearly every context, because each one
attaches it and takes its model as it is. The map restated the attach, `model_check` compared
two declarations of one fact, and the lines that carried a decision (an anticorruption layer, a
published event list, a pair kept apart) were hard to find among them.

## Decision

1. **An attach implies a relationship.** For every `attaches` the wiring makes, the map reads a
   `conformist` relationship whose upstream is the attached context and whose downstream is the
   attaching one, unless the map already says something about that pair. `ContextMap#implying`
   adds these (`Relationship#implied`) when the checks and the diagram read the map; the map as
   written is not changed.
2. **An explicit relationship between the same pair overrides it,** in either direction. An
   attach that is really a shared kernel, an open host or a partnership is declared as before,
   and a declared direction against the attach is still reported as undeclared coupling.
3. **A pair declared separate ways gets no implied relationship,** so an attach between them is
   still a `separate_ways_violated` error.
4. **An implied relationship is never unused.** It exists because the wiring does.
5. **A restating line is a warning, `:redundant_relationship`.** A bare conformist (no published
   events) that only attaches explain is dropped from the map; the finding says so. A warning
   instead of silent acceptance, because a map that keeps restating attaches puts back the
   duplication this removes, and it is quiet to fix: delete the line. A relationship that must
   stay, for a reason, acknowledges it (`acknowledges: { redundant_relationship: "reason" }`).
   A conformist is not redundant when anything but an attach couples the pair, such as a
   `translates` (which is `:conformist_translates`' business).
6. **The diagram draws an implied attach dotted and labelled `attaches`,** beside the declared
   relationships, so the whole map still reads from one picture.

No word is added: `redundant_relationship` is a finding kind, so the language bluebooks and the
Rust parser table do not change.

## Alternatives considered

- **Derive the attaches from the map.** A relationship you declare would also wire the domain.
  Loading a bluebook would then depend on a map file that is meant to be checked against the
  wiring, and framework membership (its own persistence, OIDC manifests, ports and adapters,
  ADR 0142) says more than a relationship kind does.
- **Drop the framework keywords and keep the map.** Nothing would be left to hold the map to.
- **Accept a restating line silently.** Simpler, but the duplication stays and nothing nudges a
  map toward the lines that carry a decision.

## Consequences

- A map declares only what an attach cannot say: customer/supplier with its published events,
  anticorruption layers, shared kernels, partnerships and pairs kept apart. Banking's and the
  Hecks domain's committed maps lose every attach line and keep the rest.
- A map written before this change keeps working: its restating conformist lines now warn.
- A client repository's map slims when it bumps to a hecks that carries this change.
- The checks and the diagram read the map with its implied relationships; anything that reads
  `ContextMap#relationships` directly sees only what was written.
