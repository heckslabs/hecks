# i27 — Nursery Viability Metrics (NurseryHealth capability)

Source: inbox `i27` + plan by Agent a31587a2 (v1) + Agent aa764fc9 (refined 2026-04-22).

> **Supersedes v1**: reshapes the audit from a shell/Ruby scanner into a
> first-class `Hecks.bluebook "NurseryHealth"` capability per the
> "audit-as-hecksagon" pattern. Python-ban (i37) concern is moot because
> audit runs from Rust shim via `hecks-life nursery-health` subcommand.

## Summary

Nursery has **~357 domains** ranging from full workflows to one-aggregate
sketches. Ilya's P-tier concern: README/FEATURES.md advertise breadth as
strength, but a lot is aspirational. This plan ships viability classifier
as a first-class bluebook capability (not a one-off script).

## §1 — Current state

- 357 first-level nursery dirs, 375 `.bluebook` files
- 26 parse in both Ruby AND Rust
- 349 Rust-only (all in i1/i2 Ruby DSL gap — not per-domain flaws)
- 263 fixtures in parity `soft: true`
- No signal today distinguishes rich from skeletal

## §2 — Classifier buckets

### Viable (all must hold)
1. `rust_boot_ok` — every bluebook parses in Rust
2. `aggregate_count >= 2`
3. `has_cascade` — `then_set` targets another command's `given`, OR lifecycle transition gates another command
4. `behaviors_present_and_pass` — sibling `.behaviors` + Rust runner exits 0
5. `parity_ok` — fixtures not in `fixtures_known_drift.txt`

### Partial
`rust_boot_ok` + `aggregate_count >= 1`, at least one of
{`has_cascade`, `behaviors_present`, `parity_ok`} false but NOT all three.

### Stub
`aggregate_count == 1` + `command_count <= 2` + no behaviors. Honest squatters.

### Dead
`rust_boot_ok` false. Rare; goes to antibody/repair, not viability report.

### Orthogonal flags (not bucket-determining)
- `ruby_boot_ok` / `ruby_dsl_gap` — captured, doesn't downgrade
- `has_fixtures` (data-without-assertion Partials)
- `last_touched_days` (stale Stub >90d = retirement signal)

## §3 — NurseryHealth capability

At `hecks_conception/capabilities/nursery_health/`. Four aggregates:

**NurseryScan** — one sweep (totals, bucket counts, scanned_at). Command:
`ScanNursery → NurseryScanned`.

**NurseryDomain** — per-domain record. Lifecycle on `:classification`:
`unknown → indexed → viable|partial|stub|dead`. Commands: `RecordBirth`,
`ClassifyViable/Partial/Stub/Dead`.

**ViabilityPolicy** — config aggregate, NO commands. Seeded via fixtures.
Thresholds as seeded rows so tuning = fixture change, not code change.

**NurseryKPI** — weekly rollup, command `RecordWeekly reference_to(NurseryScan)`.

### Policies
- `ClassifyAfterScan` on `NurseryScanned` → `ClassifyViable` (fanout in runtime)
- `KpiAfterScan` on `NurseryScanned` → `RecordWeekly`

## §4 — Runtime

New `hecks_life/src/run_nursery_health.rs`, registered as subcommand:

```
hecks-life nursery-health scan   [--root <path>] [--policy <name>]
hecks-life nursery-health report [--format json|text|badge]
hecks-life nursery-health weekly [--week-of YYYY-WW]
```

### `scan` algorithm
1. Resolve root, load ViabilityPolicy, read parity drift set
2. Per domain dir: parse bluebooks, count aggregates/commands, detect cascade
   (reuse `cascade::analyze`), run behaviors (reuse `behaviors_runner`), check
   fixtures + parity, `last_touched` via shell adapter git log
3. Apply classifier, dispatch lifecycle transition
4. Upsert NurseryDomain records, append NurseryScan, emit `NurseryScanned`

### Performance
Cold: ~8-15s (parity paths reused). With behaviors: ~25s. `--skip-behaviors`
for structural-only.

## §5 — Reporting

1. **CLI**: `nursery-health report` (text default)
2. **Statusline badge**: opt-in via StatusBar `show_nursery_viability` (reads cached NurseryScan, not expensive per-render)
3. **Weekly sparkline**: `--sparkline` reads last 12 NurseryKPI records

**NOT added**: blocking CI for viability. Visibility, not enforcement.

## §6 — Commit sequence (7)

1. `feat(capabilities/nursery_health): bluebook + fixtures + hecksagon skeleton`
2. `feat(nursery_health): Rust runtime shim for scan`
3. `feat(nursery_health): report subcommand (text/json/badge)`
4. `feat(nursery_health): weekly subcommand + KPI rollup`
5. `feat(status_bar): opt-in nursery viability badge`
6. `test(nursery_health): fixture nursery smoke + behaviors`
7. `docs: FEATURES.md + close inbox i27`

**Total ~900 LoC** (higher than v1's 650 — capability is reusable, introspectable, behavior-assertion-pinned).

## §7 — Risks

1. **False-positive has_cascade** — start narrow, tighten in follow-up
2. **Gaming the metric** — min-aggregate-shape guard; `behaviors_pass_rust==true` forces real assertions; stale-stub report catches dead wood
3. **Graduation from nursery** — scanner scope is `nursery/` only; dir move drops from scope. Log "graduation" when count drops without ClassifyDead
4. **Behaviors runner cost** — `--skip-behaviors` escape
5. **Ruby-DSL-gap drowning** — aggregate at top, per-domain omitted unless `--show-ruby-gap`. Goes away when i24 closes
6. **Parity drift freshness** — union with last parity run's output log

## Key files

### New
- `hecks_conception/capabilities/nursery_health/{nursery_health.bluebook, .behaviors, .hecksagon, fixtures/nursery_health.fixtures, weekly.sh}`
- `hecks_life/src/run_nursery_health.rs`
- `tests/nursery_health_smoke.sh` + `tests/fixtures/mini_nursery/`

### Modified
- `hecks_life/src/main.rs` — register subcommand
- `hecks_conception/capabilities/status_bar/status_bar.bluebook` — `show_nursery_viability`
- `FEATURES.md`, `CLAUDE.md`, `docs/plans/INDEX.md`

### Reused
- `hecks_life/src/{parser.rs, ir.rs, cascade.rs, behaviors_runner.rs}`
- `spec/parity/fixtures_known_drift.txt`, `NURSERY_BLUEBOOK_INVENTORY.md`

## Dependencies

None unshipped. i37 Phase A already available. i42/i43 optional.
