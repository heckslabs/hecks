# i51 Phase A + first-half-of-B — retrospective

Written after three modules retired on 2026-04-23: `validator.rs`, `validator_warnings.rs`, `dump.rs`. Plan §9 commit 7 called for a Phase A retrospective; what we have is richer — 4 PRs of real data.

## Retired, tally

| Module | PR | Bytes generated | Shape aggregates | Fixtures | Embedded snippets |
|---|---|---:|---:|---:|---:|
| validator.rs | #340/343/344 | 7,849 | 4 | 75 | 0 |
| validator_warnings.rs | #346 | 5,153 | 1 | 2 | 1 |
| dump.rs | #347/348 | 5,987 | 3 | 72 | 1 |
| **Total** | | **18,989** | **8** | **149** | **2** |

Every byte regenerable from shape. `specializer_golden_test` fires on hand-edit drift. CI green every step.

## What the taxonomy handles

Across 3 modules, these specializer primitives emerged. Everything else went `embedded`.

### validator (Phase A) — rule primitives
- `unique` — HashSet-based dedup → error list
- `non_empty` — iter().filter().map(format!()).collect()
- `first_word_verb` — sui-generis word classifier (NOT embedded — templated because 6 rules share it)
- `reference_valid` — nested HashSet + domain.is_some() skip
- `trigger_valid` — HashSet + iter()/filter()/map() chain
- `unique_across` — HashSet across all aggregates

### validator_warnings (Phase B.1) — warning primitives
- `count_threshold` — len > N → Some(msg); otherwise None
- `graph_components` — *(declared but not actually templated; went embedded)*

### dump (Phase B.2) — JSON mapping primitives
- `direct` — `"key": binding.source`
- `recurse_list` — `.iter().map(fn).collect::<Vec<_>>()`
- `recurse_optional` — `.as_ref().map(fn)`
- `helper_call` — `fn(&binding.source)`
- `normalize` — `normalize_value(&binding.source)`
- `fixture_pairs` — special Vec<[k, normalize_value(v)]> shape

### Body-kind dispatch (above the primitives)
- `json_object` — `json!({ ... })` from JsonField rows
- `embedded_helper` — read `.rs.frag` snippet as function body
- `enum_match` — `match` expression from EnumCase rows

## What the taxonomy can NOT handle

Two `embedded` rules shipped. Both for a reason:

1. **`mixed_concerns_warning`** (validator_warnings) — 108 LoC BFS over reference/policy adjacency graph. Needs declarative graph-component IR. Filed as **i58** (LOW).

2. **`normalize_value`** (dump) — 15 LoC whitespace-cleanup string utility. Tight, char-by-char state machine. Probably *always* deserves a snippet — forcing it into IR would be purity theater.

**Rule of thumb:** if the body touches data structure traversal (BFS, pattern match, control flow), that should eventually be IR. If the body is a stateful string munger, snippet is honest.

## Declarativity ratios — what earned retirement

| Module | Declarative fns | Total fns | Ratio |
|---|---:|---:|---:|
| validator | 6/6 rules + 2 helpers | 8 | **100%** |
| validator_warnings | 1/2 warnings | 2 | 50% |
| dump | 13 json_object + 1 enum_match | 15 | **93%** |

**dump's 93% is the cleanest retirement.** The canonical-IR serializer was *meant* to be declarative — we just gave it a home to live in.

**validator_warnings' 50% is honest debt.** The graph algorithm resists shape, and that's a real signal. The escape hatch (`.rs.frag`) kept it visible rather than hiding it.

## The Ruby-adapter-per-target pattern

Every retirement has its own `bin/specialize-X` script. They share ~80 LoC of boilerplate:

- Load `hecks-life dump-fixtures` JSON
- Group by aggregate name
- CLI with `--output` / `--diff` / stdout fallback
- Tempfile-based diff mode

This is ripe for consolidation into a single `bin/specialize` driver with per-target Ruby modules under `lib/hecks_specializer/`. Phase C prep: **when the specializer becomes its own bluebook, there's one thing to specialize, not three.**

Follow-up filed implicitly by this doc — will land as the next PR after this one.

## When NOT to specialize

Parsers are the wall. `fixtures_parser.rs` (440 LoC), `hecksagon_parser.rs`, `behaviors_parser.rs` — all **sui generis** string-state-machine code. Depth counters, escape-aware splitters, multi-line block detection. No IR shape compresses it usefully today.

**Options when this comes up:**

1. Ship as `embedded` with per-fn snippets — proves the pipeline, gains nothing
2. Grow the IR (L2/L3) until parser bodies fit — real work, unbounded scope
3. **Skip to declarative modules** — what we did, redirecting to `dump.rs`

Option 3 is the honest path. Specialize where specialization earns its keep.

## Ruby/Rust parity — the hidden prize

Before Phase B.2, `dump.rs` and `canonical_ir.rb` (the Ruby side) were hand-kept in sync via the parity suite. Hoping every field added to one side got added to the other. Tests caught drift; nothing prevented it.

After Phase B.2, the canonical-IR shape lives in `dump_shape.fixtures`. Adding a field becomes a fixture edit. **The Ruby side can be regenerated from the same source** when its specializer lands (Phase E, deferred).

This is the quiet win. The 18,989 bytes of retired Rust is cumulative; the Ruby/Rust parity contract moving into shape fixtures is structural.

## Phase C preview — specializer as bluebook

The specializer itself is still hand-written Ruby (`bin/specialize-*`, ~1000 LoC total). Phase C applies the same treatment to the specializer:

1. Describe the specializer's behaviour as its own `specializer.bluebook` (already have the scaffold — L0..L8 layers, projections, targets).
2. Add aggregates for the emission rules (mapping_kind primitives, body_kind dispatch).
3. Write a meta-specializer that reads its own shape and emits the Ruby (or Rust).
4. Apply the meta-specializer to itself. Output should be byte-equivalent to the hand-written Ruby.
5. Fixed-point: `binary_N == binary_(N+1)`. Self-hosting.

This is the 2nd Futamura projection. The payoff: **the specializer compiles itself.** After that, *adding a specializer primitive is a fixture edit,* same as validator rules.

## Load-bearing constraints that held

From plan §6:

- **C1 (heartbeat preservation)** — every retirement ran with Miette's tick alive. Regeneration is a one-shot; no live-runtime risk.
- **C2 (parity-testable)** — golden test gates every module. Hand-edits to any retired `.rs` fail CI.
- **C3 (no rustc shipped)** — specializer is Ruby, cargo stays external. Binary still ships as one artifact.
- **C4 (capability-first wiring)** — every specializer dispatched through the `:autophagy` gate in `specializer.hecksagon`. No opaque scripts.

## What Phase B changes (vs plan's assumption)

The plan assumed commit 6 retires validator.rs and commits 7+ extend through the §7 list in order. Three changes held:

1. **Commit squashing.** Plan had 7 commits for Phase A; we shipped 4 PRs (commits 1+{2+3+4+5}+6+7). Byte-identity gate let us collapse without losing evidence.

2. **Module ordering.** Plan said parsers after validators; we jumped to `dump.rs` (plan §7 step 3, "almost declarative") because it had the best return on specialization effort. Parsers are deferred until the IR grows.

3. **Escape hatch first, taxonomy lift later.** `embedded` body-strategy ships in validator_warnings before i58's proper graph-IR primitives. Honest debt, named, survivable.

## Open follow-ups

- **i57** — Rust `fixtures_parser` doesn't read multi-line `fixture` directives. Worked around by collapsing to single-line; all shape fixtures are single-line today.
- **i58** — specializer `check_kind` taxonomy needs graph-component primitives. `mixed_concerns` embedded in the meantime.
- **Next PR after this** — consolidate `bin/specialize-*` into single `bin/specialize` driver + `lib/hecks_specializer/` modules.
- **Phase C** — specializer bluebook-ification. 2nd Futamura.
- **Phase B step 7 (deferred)** — parsers. When the IR is ready.

## Tally for the day

- 3 modules retired
- 18,989 bytes of hand-written Rust → regenerated from shape
- 8 shape aggregates, 149 fixtures
- 4 golden tests (1 wiring + 3 byte-identity), all green
- 0 regressions in the daily parity suite
- 1 new escape hatch pattern (`.rs.frag` snippet), named + bounded

Pattern is proven. Phase C next.
