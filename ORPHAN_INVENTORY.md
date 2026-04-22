# Orphan Inventory — .fixtures and .behaviors

Aggregate-reference check: for each `.fixtures` and `.behaviors` file,
confirm every `aggregate` / `on:` reference resolves to an aggregate
declared in a `.bluebook` for the matching `Hecks.<kind> "Domain"`.

Generated: 2026-04-21

## Corpus

- `.bluebook` files scanned: 480
- Distinct domain names declared: 468
- `.fixtures` files scanned: 356
- `.behaviors` files scanned: 455

## .fixtures

### Counts

| Category | Files |
|---|---|
| All aggregate refs found in bluebook | 354 |
| Some orphans (partial match) | 1 |
| All refs orphan | 1 |
| Domain name not declared in any bluebook | 0 |
| No aggregate refs present | 0 |
| **Total** | 356 |

### .fixtures — some orphans

**`hecks_conception/aggregates/fixtures/sleep.fixtures`** — domain `"Sleep"`
  - L2: `Fatigue` — ORPHAN
  - L10: `WakeMood` — OK
  - L16: `Consciousness` — OK
  - L21: `Monitor` — OK

### .fixtures — all orphans

**`hecks_conception/capabilities/antibody/fixtures/antibody.fixtures`** — domain `"Antibody"`
  - L9: `FlaggedExtension` — ORPHAN
  - L31: `ShebangMapping` — ORPHAN
  - L47: `ExemptionPattern` — ORPHAN
  - L58: `TestCase` — ORPHAN

## .behaviors

### Counts

| Category | Files |
|---|---|
| All aggregate refs found in bluebook | 454 |
| Some orphans (partial match) | 0 |
| All refs orphan | 0 |
| Domain name not declared in any bluebook | 0 |
| No aggregate refs present | 1 |
| **Total** | 455 |

### .behaviors — no aggregate refs present

**`hecks_conception/aggregates/bluebook.behaviors`** — domain `"Bluebook"`
  A scaffold with section-comment headers for every Bluebook aggregate
  (Domain, Aggregate, Attribute, ValueObject, Reference, Command, Query,
  Given, Mutation, Lifecycle, Transition, Policy, Fixture) but no
  `tests … on: …` blocks yet. Not an orphan — an unwritten draft.

## Notes on Findings

### `Fatigue` in `aggregates/fixtures/sleep.fixtures`

The `Fatigue` aggregate was removed from `aggregates/sleep.bluebook` on
2026-04-20 (see the header comment in that file). The fixtures file was
not updated — `aggregate "Fatigue"` at L2 with six fixtures is now
referencing an aggregate that no longer exists. Safe to delete.

### Antibody fixtures as config tables

All four aggregates in `capabilities/antibody/fixtures/antibody.fixtures`
(`FlaggedExtension`, `ShebangMapping`, `ExemptionPattern`, `TestCase`)
are orphans in the strict sense — they are not declared as aggregates
in `antibody.bluebook`. The file is being used as a config/seed table
(CODE_EXTS, shebang map, exemption regex, test scenarios) rather than
as seed data for bluebook-declared aggregates. Either the bluebook
should grow formal aggregates for these, or these config rows belong
somewhere else (a `.heki` store, or a dedicated config format).
