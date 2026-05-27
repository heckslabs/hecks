---
ref: i737
title: status_coherence conversion blocked by 3 undeclared runtime writes
status: open
category: runtime-gap
filed_by: sidequest
filed_at: 2026-05-24
---

# i737 — status_coherence conversion runtime gaps (3 sub-points)

Three heki writes happen at runtime with no corresponding bluebook declaration,
blocking 3 of the 6 coherence invariants from being expressible as pure queries.

## GAP-1 — sleep_stage / is_lucid not declared on Mind::Consciousness

`mindstream.sh` writes `sleep_stage` and `is_lucid` to `consciousness.heki` at
runtime, but neither attribute is declared on the `Mind::Consciousness`
aggregate. Queries that read these fields are not type-safe from the bluebook's
perspective.

## GAP-2 — latest_narrative not declared on Mind::LucidDream

`latest_narrative` is written to `lucid_dream.heki` at runtime but is absent
from `Mind::LucidDream`'s attribute list. Same consequence: the field is
invisible to the IR and to any storehouse-driven query.

## GAP-3 — Tick aggregate does not exist as a bluebook

`mindstream.sh` writes `tick.heki` entirely undeclared — there is no `Tick`
aggregate in any bluebook. The write is fully outside the domain model.

## Fix shape

For GAP-1 and GAP-2: add the missing attributes to the respective aggregates.
For GAP-3: declare a `Tick` aggregate (minimally: `timestamp`, `beat_count`,
`source`) so the runtime write has a home and queries can be expressed cleanly.
