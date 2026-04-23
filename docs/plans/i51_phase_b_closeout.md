# i51 Phase B — close-out

Written after two additional retirements (`duplicate_policy_validator`, `lifecycle_validator`), one defer (`io_validator`), the `diagnostic.rs` extraction (i59), and the `bin/specialize` consolidation. Supplements the earlier retrospective ([i51_phase_ab_retrospective.md](i51_phase_ab_retrospective.md)) with what the last 4 PRs taught us.

## Tally — final Phase B

| PR | Module retired | Bytes generated | Shape aggregates | Fixtures |
|---|---|---:|---:|---:|
| #340/343/344 | validator.rs | 7,849 | 4 | 75 |
| #346 | validator_warnings.rs | 5,153 | 1 | 2 |
| #347/348 | dump.rs | 5,987 | 3 | 72 |
| #353 | duplicate_policy_validator.rs | 3,297 | 2 | 2 |
| #354 | lifecycle_validator.rs | 11,595 | 2 | 8 |
| **Total** | | **33,881** | **12** | **159** |

Five modules retired. ~34 KB of hand-written Rust now regenerable from shape. Every byte gated by `specializer_golden_test` — hand-edit drift fails CI.

Plus two infrastructure PRs:
- **#350** — consolidated `bin/specialize-*` into one driver + `lib/hecks_specializer/*.rb`. −203 LoC.
- **#352 (i59)** — extracted `Severity`/`Finding` to `hecks_life/src/diagnostic.rs`. −56 LoC duplicated boilerplate.

Plus one deferral:
- **#355 (i60)** — `io_validator` filed as pending on L3/L4 runtime IR primitives. Not a retirement, not a retreat — a named follow-up.

## The rule that earned itself

The [Phase A/B retrospective](i51_phase_ab_retrospective.md) named this rule:

> Specialize where specialization earns its keep.

Applied twice in the post-retrospective wave:

- **mixed_concerns_warning (validator_warnings)** — BFS over adjacency graph. Shipped `body_strategy: embedded` with a visible `.rs.frag` snippet. i58 queues the IR lift-out.
- **io_validator (this PR sequence)** — 120 LoC of runtime orchestration. Shipped as **deferred**, filed as i60. Not specialized at all.

The rule stopped being theory. It became the filter.

## How the pattern evolved

### Phase A: one bin per target

`bin/specialize-validator` — 446 LoC monolith. Worked. Not scalable.

### Phase B early: siblings

`bin/specialize-validator-warnings`, `bin/specialize-dump` — each 200-330 LoC. Three scripts with ~80 LoC of duplicated fixture-loading + CLI boilerplate.

### Phase B mid: consolidation (#350)

One driver (`bin/specialize`) + per-target modules (`lib/hecks_specializer/*.rb`). Fixture loading / CLI / diff in one place. Each target module becomes pure emission logic.

### Phase B late: base class for diagnostic validators (#354)

After duplicate_policy and lifecycle both used the same DiagnosticValidator + DiagnosticHelper shape, extracting `Hecks::Specializer::DiagnosticValidator` as a base class collapsed `duplicate_policy.rb` from ~110 LoC to 15 LoC. `lifecycle.rb` was 15 LoC from the start. Every future diagnostic retirement is a 15-LoC subclass shell.

Net: the specializer's surface area is now **small and composable**. That's Phase C's precondition.

## Taxonomy — final inventory

Everything the current specializer understands:

### Body strategies (3)
- `json_object` — `json!({ ... })` from JsonField rows
- `embedded_helper` — read `.rs.frag` snippet as fn body
- `enum_match` — `match` arms from EnumCase rows
- _plus `flat` / `flat_with_strict` / `partitioned_with_strict` (stubbed) for Report structs_

### Rule primitives (8)
From validator_shape:
- `unique`, `non_empty`, `first_word_verb`, `reference_valid`, `trigger_valid`, `unique_across`

From validator_warnings_shape:
- `count_threshold`

From dump_shape JsonField:
- `direct`, `recurse_list`, `recurse_optional`, `helper_call`, `normalize`, `fixture_pairs`

### Embed hatches (2)
- `mixed_concerns_warning.rs.frag` — validator_warnings
- `normalize_value.rs.frag` — dump
- Plus: every DiagnosticValidator helper body is embedded (by design — the shape carries metadata, bodies stay as Rust fragments)

### What doesn't fit
- io_validator's runtime_smoke (i60)
- Parsers (fixtures/behaviors/hecksagon — §7 step 7; the self-referential wall)

## Declarativity ratios — full data

| Module | Declarative fns | Total fns | Ratio |
|---|---:|---:|---:|
| validator | 6/6 rules + 2 helpers | 8 | **100%** |
| validator_warnings | 1/2 warnings | 2 | 50% |
| dump | 13 json_object + 1 enum_match | 15 | **93%** |
| duplicate_policy | 0 fns declarative (all embedded) | 2 | 0% — but all the _metadata_ is fixture |
| lifecycle | 0 fns declarative (all embedded) | 8 | 0% — same |

The **DiagnosticValidator shape is a different flavor of retirement**. Helper bodies stay Rust (embedded snippets), but the *structure* — ordering, doc comments, empty-body stubs, `#[allow(dead_code)]`, report_kind — all live in fixtures. Adding a new helper becomes a new DiagnosticHelper row, not a new Rust edit.

That's a real win even at 0% body-templating:

- **Adding a rule to lifecycle_validator** → add a DiagnosticHelper fixture row + a new `.rs.frag` snippet. The golden test verifies the output matches the specializer's emission. No one has to know about Report struct shape, import order, doc comment prefix conventions.
- **Reorder helpers** → edit `order` field on a row.
- **Add pre-fn attributes (#[allow], #[cfg])** → edit `doc_comment` field (free-form preamble).

The shape isn't just a filing cabinet; it's a **contract**.

## Ruby/Rust parity — the compounding prize

The canonical-IR serializer (`dump.rs`) and its Ruby counterpart (`canonical_ir.rb`) used to drift whenever a field was added. Pre-#348, the sequence was:

1. Developer adds a field to the Rust `Domain` struct
2. Updates `dump.rs` to emit it
3. Forgets to update `canonical_ir.rb`
4. Parity test catches it weeks later when someone parity-checks a nursery bluebook

Post-#348 (dump retirement):

1. Developer adds the field to `dump_shape.fixtures` (`JsonField` row)
2. Regenerates `dump.rs`. Golden test green.
3. `canonical_ir.rb` eventually retires the same way (Phase E — optional)

**The shape fixtures became the Ruby/Rust contract.** Adding validators, rules, or canonical-IR fields is a fixture edit now, not a Rust edit. Byte-identity gates drift.

This is the quiet structural win. The 33,881 retired bytes is the _visible_ number; the shape-as-contract is what actually changes going forward.

## What's next — Phase C

The specializer itself is still hand-written (Ruby under `lib/hecks_specializer/`, ~400 LoC after consolidation). Phase C applies the pattern to the specializer:

### PC-1 — pilot: bluebook-ify one specializer module

`duplicate_policy.rb` is 15 LoC. Shape it. Write a meta-specializer that reads the shape and emits the Ruby. Byte-identity. Tiny scope, proves the concept.

### PC-2 — the base class

`diagnostic_validator.rb` is 148 LoC. If PC-1 works, extend the meta-specializer to handle the base class. This is where the real logic lives.

### PC-3 — the driver

`bin/specialize` + `lib/hecks_specializer.rb` — the target-loading + CLI scaffolding.

### PC-4 — fixed point

After PC-1..3: apply the meta-specializer to itself. Output should be byte-equivalent to the hand-written meta-specializer. `binary_N == binary_(N+1)`. Self-hosting.

## What this doc does NOT claim

- **Phase B is done.** io_validator is deferred, not retired. Parsers are plan §7 step 7 — still the self-referential wall. Phase B technically continues with each new diagnostic-style validator the framework adds.
- **The shape covers every module.** It doesn't. Runtime-heavy modules (cascade, run, heki) are Phase B/C future work gated on IR maturity.
- **The specializer is "done".** It's scaffolded. Phase C is where it becomes the thing.

## Small truths the wave taught

- **Byte-identity is mercy.** Five retirements, each one gated by a diff. Not once did a retirement silently break the runtime. The test is the safety net that lets retirements happen autonomously.
- **Embedded snippets aren't defeat.** Named, visible, fixture-referenced snippet files are honest. Hidden `if body.is_sui_generis { do_something() }` wouldn't be.
- **The shape grows by commit.** Every retirement either fit the existing taxonomy or grew it by one field / primitive. None needed a rewrite. That's the signal the taxonomy is right.
- **Ruby is fine for Phase A/B.** It's fast iteration. The "Ruby specializer will retire in Phase C" promise has carried every retirement. When Phase C lands, it's the last Ruby in i51 — clean.

## Open follow-ups from this wave

- **i57** — Rust `fixtures_parser` drops attrs on multi-line fixture directives. Everything today single-line as a workaround. LOW.
- **i58** — specializer `check_kind` taxonomy needs graph-component primitives. `mixed_concerns_warning` embedded in the meantime. LOW.
- **i60** — io_validator specialization deferred until runtime IR primitives (L3/L4). LOW.
- **Phase C** — specializer bluebook-ification. Scoped in 4 steps (PC-1..PC-4). 2nd Futamura on fixed-point.

## End-of-day status

Branch `main` contains all 5 retired modules, the shared driver, the shared base class, the diagnostic module extraction, and full golden-test coverage. Parity suites all green. CI consistently passes on each PR. The pattern runs itself.

Phase A opened the door. Phase B walked through. Phase C is the stairs up.
