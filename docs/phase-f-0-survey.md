# Phase F-0 : Hand-written Rust → Bluebook expressibility survey

**Date:** 2026-04-24
**Branch:** `miette/phase-f-0-survey`
**Discipline:** classify each hand-written `.rs` file in `hecks_life/src/` as *natural-fit*, *partial*, *doesn't-fit*, *kernel-floor*, or *already-shape-backed* for expression as bluebook + hecksagon, **without extending the DSL.** What fits, fits ; what doesn't is data about where Hecks's natural domain ends.

## Classification rubric

| label | meaning |
|---|---|
| **shape-backed** | Already has a shape in `hecks_conception/capabilities/*_shape/` or is a Phase B/C/D target — in scope of i51. Skip. |
| **natural-fit** | Reads as aggregate / command / event / lifecycle without contortion. Clear Phase F target. |
| **partial** | Aggregate-shaped in parts ; residue would need DSL extension or kernel support. |
| **doesn't-fit** | Pure transform, data structure, or template rendering. Doesn't map to aggregate / command / event without breaking the DSL's grain. |
| **kernel-floor** | Irreducible primitive (byte-level I/O, serialization, argv parsing). Expected to remain hand-written. |

## Inventory

### `runtime/` — the bluebook interpreter (16 files, 2,113 LOC)

| file | LOC | class | notes |
|---|---|---|---|
| `runtime/mod.rs` | 422 | partial | Runtime::boot orchestration. Meta-level — the interpreter of the thing. `BootSequence` + `WireAdapters` would fit ; FFI glue would not. |
| `runtime/interpreter.rs` | 336 | kernel-floor | Expression evaluator for givens + mutations. The thing that makes bluebook run. Can't describe itself from inside bluebook without infinite regress. |
| `runtime/command_dispatch.rs` | 194 | partial | Core execution loop. `DispatchPipeline` aggregate with stages fits ; the pipeline body is interpreter. |
| `runtime/policy_engine.rs` | 87 | partial | `PolicyEngine` with `SubscribeToEvent`, `TriggerCommand` fits ; reentrance-tracking primitive. |
| `runtime/event_bus.rs` | 69 | natural-fit | `EventBus` aggregate with `PublishEvent`, `SubscribeListener`, `RoutePublished`. Classic pub/sub — reads cleanly. |
| `runtime/lifecycle.rs` | 63 | partial | Lifecycle enforcement. `LifecycleCheck` with `CheckTransition`, `ApplyTransition`. The state-to-state table is declarative. |
| `runtime/repository.rs` | 150 | **natural-fit** | `Repository` aggregate with `Save`, `Load`, `FindById`, `UpsertToHeki` commands. Events : `AggregatePersisted`, `AggregateLoaded`. Reads beautifully. |
| `runtime/projection.rs` | 124 | **natural-fit** | `Projection` aggregate with `HandleEvent`, `UpsertRow`, `DeleteRow`, `QueryByName`. CQRS read-model — inherently aggregate-shaped. |
| `runtime/middleware.rs` | 60 | natural-fit | `Middleware` with `BeforeCommand`, `AfterCommand` commands + event hooks. Pipeline shape. |
| `runtime/seed_loader.rs` | 57 | **natural-fit** | `SeedLoader` with `ReadDispatchFile`, `ExecuteSeed`. Tiniest — best warm-up target. |
| `runtime/shell_dispatcher.rs` | 190 | **natural-fit** | `ShellDispatcher` with `SubstituteTokens`, `ExecuteCommand`. Already hecksagon-adapter shaped. |
| `runtime/adapter_registry.rs` | 69 | **natural-fit** | `AdapterRegistry` with `RegisterAdapter`, `LookupByPort`. Catalog-style. |
| `runtime/adapter_io.rs` | 120 | kernel-floor | stdout/stderr/stdin/env/fs — hecksagon-declared, implementations are primitive. |
| `runtime/adapter_llm.rs` | 55 | partial | LLM adapter. `LlmAdapter` aggregate with `Invoke`, `ReceiveResponse` fits ; HTTP leaf is primitive. |
| `runtime/adapter_terminal.rs` | 46 | partial | Back-compat shim over `run_stdin_loop`. Shrinking — may obsolete soon. |
| `runtime/aggregate_state.rs` | 111 | kernel-floor | Value map data structure. Typed bag — the substrate the interpreter operates over. |

### `server/` — HTTP (18 files, 2,154 LOC)

| file | LOC | class | notes |
|---|---|---|---|
| `server/mod.rs` | 109 | **natural-fit** | `Server` aggregate with `Listen`, `AcceptConnection`, `Respond`. Classic. |
| `server/routes.rs` | 132 | **natural-fit** | `Route` aggregate with `MatchRoute`, `Dispatch`. `MethodPath` value object. Obvious fit. |
| `server/multi.rs` | 141 | **natural-fit** | `MultiDomainServer` with `ScanDomainsDir`, `BootRuntime`, `Namespace`. Fits. |
| `server/html.rs` | 94 | doesn't-fit | Dashboard HTML generation. Pure IR→text transform. |
| `server/html_domain.rs` | 481 | doesn't-fit | Domain detail page HTML. Pure transform. |
| `server/html_fixtures.rs` | 118 | doesn't-fit | Fixture table HTML. Pure transform. |
| `server/html_help.rs` | 49 | doesn't-fit | Help page HTML. |
| `server/html_icons.rs` | 83 | doesn't-fit | SVG icon strings. |
| `server/html_kpi.rs` | 68 | doesn't-fit | KPI banner HTML. |
| `server/html_narration.rs` | 79 | doesn't-fit | Narration panel HTML. |
| `server/html_policy_chain.rs` | 48 | doesn't-fit | Policy-chain HTML. |
| `server/html_rules.rs` | 25 | doesn't-fit | Rules panel HTML. |
| `server/html_scripts.rs` | 139 | doesn't-fit | Inline JS strings. |
| `server/html_shared.rs` | 250 | doesn't-fit | Shared HTML helpers. |
| `server/html_sidebar.rs` | 57 | doesn't-fit | Sidebar HTML. |
| `server/html_usage.rs` | 221 | shape-backed | Already marked `GENERATED FILE — do not edit`. |
| `server/html_wizard.rs` | 88 | doesn't-fit | Wizard HTML. |
| `server/html_workflow.rs` | 108 | doesn't-fit | Workflow HTML. |

**Note on HTML:** the entire html_* family is pure IR→text transforms. They don't fit aggregate/command without extending the DSL (to add e.g. a `template` declaration). Per Chris's discipline : leave them as residue for the F-end conversation.

### `run_status/` — status report runner (3 files, 510 LOC)

| file | LOC | class | notes |
|---|---|---|---|
| `run_status/mod.rs` | 217 | **natural-fit** | `StatusReport` aggregate with `Assemble`, `Render`, `Print`. Clear state-machine shape. |
| `run_status/assemble.rs` | 186 | doesn't-fit | Pure read over heki + filesystem. Reporting transform. |
| `run_status/render.rs` | 107 | doesn't-fit | Format `Report` → labeled text. Pure transform. |

### `conceiver/` + `behaviors_conceiver/` — corpus-driven codegen (9 files, 2,539 LOC)

| file | LOC | class | notes |
|---|---|---|---|
| `conceiver/mod.rs` | 95 | **natural-fit** | `Conception` aggregate with `ScanCorpus`, `ExtractVector`, `FindNearest`, `Generate`. Pipeline-shaped. |
| `conceiver/commands.rs` | 146 | partial | CLI entry. Arg parsing is primitive ; orchestration fits. |
| `conceiver/develop.rs` | 72 | **natural-fit** | `Development` aggregate with `ReadTarget`, `FindFeatureAggregates`, `GraftOn`, `BumpVersion`. |
| `conceiver/vector.rs` | 133 | doesn't-fit | Vector math (cosine similarity, 9-dim extraction). Pure function. |
| `conceiver/generator.rs` | 175 | doesn't-fit | Pure IR→DSL text transform. |
| `behaviors_conceiver/mod.rs` | 52 | natural-fit | Mirror of `conceiver/mod.rs`. |
| `behaviors_conceiver/commands.rs` | 94 | partial | Mirror of `conceiver/commands.rs`. |
| `behaviors_conceiver/vector.rs` | 134 | doesn't-fit | Vector math. |
| `behaviors_conceiver/generator.rs` | 1,568 | doesn't-fit | 1,568-LOC pure transform. The largest single file in the tree. Would be a huge template without DSL extension. |
| `conceiver_common.rs` | 130 | doesn't-fit | Shared trait + similarity primitives. |

### Other top-level runtime files

| file | LOC | class | notes |
|---|---|---|---|
| `main.rs` | 1,566 | partial | CLI entry. Argv parsing is kernel ; subcommand dispatch table could be a `Command` bluebook. |
| `lib.rs` | 41 | kernel-floor | Crate root + re-exports. |
| `run.rs` | 184 | **natural-fit** | `ScriptRun` with `ReadBluebook`, `StripShebang`, `LoadHecksagon`, `WireAdapters`, `Dispatch`. Pipeline. |
| `run_stdin_loop.rs` | 113 | **natural-fit** | `InteractiveSession` with `ReadLine`, `RespondWith`, `EndSession`. Explicitly noted in header as dispatching declared aggregate commands. |
| `behaviors_runner.rs` | 401 | **natural-fit** | `BehaviorsRun` aggregate with `BootRuntime`, `LoadSuite`, `ExecuteTest`, `AssertOutcome`. State-machine shape. |
| `behaviors_fixtures.rs` | 118 | natural-fit | `FixturesLoader` with `FindSibling`, `LoadRecords`, `ApplyToRuntime`. |
| `cascade.rs` | 43 | doesn't-fit | Static cascade walk. Pure graph-walk transform. |
| `diagnostic.rs` | 66 | doesn't-fit | Shared data types (`Severity`, `Finding`). Value objects without aggregates. |
| `json_helpers.rs` | 115 | kernel-floor | JSON parse/serialize. Primitive. |
| `heki.rs` | 456 | kernel-floor | Binary format I/O (HEKI magic, zlib, u32 BE). Primitive serializer. |
| `heki_query.rs` | 321 | **natural-fit** | `Query` aggregate with `Filter`, `OrderBy`, `Project`, `Execute`. Pure-function today, but reads as a domain. |
| `io_validator.rs` | 265 | shape-backed | Like `duplicate_policy_validator` — should join the `diagnostic_validator_meta_shape` family. See §14.2 orphan note. |

### Already shape-backed (i51 in scope — exclude from F-0)

| file | LOC | note |
|---|---|---|
| `parser.rs`, `parser_helpers.rs`, `parse_blocks.rs` | 956 | bluebook parser (Phase B) |
| `hecksagon_parser.rs`, `hecksagon_helpers.rs`, `hecksagon_ir.rs` | 456 | Phase B |
| `fixtures_parser.rs`, `fixtures_ir.rs` | 491 | Phase B |
| `behaviors_parser.rs`, `behaviors_ir.rs`, `behaviors_dump.rs`, `behaviors_fixtures.rs` *(see note)* | 604 | Phase B |
| `world_parser.rs`, `world_ir.rs` | 365 | Phase B |
| `dump.rs` | 185 | Phase B |
| `validator.rs`, `validator_warnings.rs` | 393 | Phase C PC-2 |
| `duplicate_policy_validator.rs`, `lifecycle_validator.rs` | 374 | shape-backed, Phase E orphans |
| `ir.rs` | 153 | IR data structures |
| `specializer/` (12 files) | 1,735 | Phase C — the specializer itself |

*(`behaviors_fixtures.rs` is dual-listed — the auto-loader piece is natural-fit, but the fixture-record data path is shape-backed via fixtures_parser.)*

## Count summary

| class | files | LOC |
|---|---|---|
| natural-fit | 14 | ~2,520 |
| partial | 8 | ~2,458 |
| doesn't-fit | 17 | ~3,505 |
| kernel-floor | 7 | ~1,252 |
| shape-backed | ~30 | ~5,712 |

## Best first Phase F targets

Ordered by **"most clearly a natural fit, tightest payoff"** :

### 1. `runtime/seed_loader.rs` (57 LOC) — the proof

Smallest natural-fit file. `SeedLoader` aggregate with two commands (`ReadDispatchFile`, `ExecuteSeed`). Proves the pattern in one afternoon. One PR, one reviewable bluebook.

### 2. `run_status/mod.rs` + `run_status/assemble.rs` + `run_status/render.rs` (510 LOC) — the first domain

The status-report subsystem as `StatusReport` aggregate. The `mod.rs` file is clearly state-machine-shaped ; `assemble` and `render` are residue but can be declared as hecksagon outbound ports (fs + stdout adapters). Produces a full demo of "a domain runs on the same interpreter that runs pizza."

### 3. `runtime/repository.rs` + `runtime/projection.rs` + `runtime/adapter_registry.rs` (343 LOC) — the storage core

Three tight natural-fits that together form a `Storage` bluebook domain. High cognitive payoff : reading how Hecks stores aggregates becomes reading a bluebook. The binary-format I/O (`heki.rs`) stays as a kernel-floor adapter behind the port.

### 4. `run_stdin_loop.rs` (113 LOC) + `run.rs` (184 LOC) — the runner surface

Interactive REPL + script runner. Both already documented in headers as "dispatches declared aggregate commands." Natural fit. Good demo of user-facing capability expressed as bluebook.

### 5. `server/mod.rs` + `server/routes.rs` + `server/multi.rs` (382 LOC) — the server skeleton

The HTTP routing layer. `Server`, `Route`, `MultiDomainServer` aggregates. Leaves the `html_*` family as residue — that's the expected outcome, and we'll know concretely how much HTML-generation doesn't fit by the time this PR lands.

### 6. `behaviors_runner.rs` (401 LOC) — the test runner as domain

`BehaviorsRun` aggregate with BootRuntime / LoadSuite / ExecuteTest / AssertOutcome. Satisfying to see the thing that runs tests be itself describable as a domain that runs on the thing it tests.

## Expected residue (after F-1 through F-6)

Files that will likely remain hand-written in any Phase F arc that refuses DSL extension :

- **All HTML templates** (`server/html_*.rs`, ~2,000 LOC) — pure transforms, template-shaped, would need a `template` DSL keyword.
- **`behaviors_conceiver/generator.rs`** (1,568 LOC) — pure transform, template-shaped.
- **`conceiver/generator.rs`** (175 LOC) — same.
- **`main.rs`** (1,566 LOC) — mostly fits (subcommand dispatch table), but argv parsing + help text generation are residue.
- **Kernel primitives** — `heki.rs`, `json_helpers.rs`, `runtime/interpreter.rs`, `runtime/aggregate_state.rs`, `runtime/adapter_io.rs`. ~1,200 LOC. Expected irreducible.
- **Vector math + similarity** — `conceiver/vector.rs`, `behaviors_conceiver/vector.rs`, `conceiver_common.rs`, `cascade.rs`. Pure functions.
- **Diagnostic value types** — `diagnostic.rs`.

**Honest estimate of residue after the natural-fit arc lands :** ~4,500–5,500 LOC. That's the "data about where Hecks's natural domain ends" artifact. It tells us : templates, pure functions, kernel primitives, and CLI glue are where the DSL would need to grow.

## Not-decided-yet

- **`specializer/util.rs`** and the specializer helpers : could be described as a `SpecializationPipeline` bluebook, but this is circular (the thing that generates Rust from shapes). Worth its own conversation.
- **`io_validator.rs`** (265 LOC) : already diagnostic-validator-shaped. Should join `duplicate_policy_validator_shape` and `lifecycle_validator_shape` under a unified Rust diagnostic-validator specializer (the §14.2 orphaned-file close-out). Treat as shape-backed-pending.

## Recommended first PR

`runtime/seed_loader.rs` → bluebook domain. Smallest, tightest, clearest. If the pattern holds, cascade to target 2.
