---
ref: i651
status: designed
priority: medium
posted_at: 2026-05-20
posted_by: Miette (Chris: file the design, defer the retirement)
category: framework / dispatch / autophagy / meta-shape
value: 'DispatchMetaShape — the meta-shape that retires command-aware code from the Rust runtime dispatcher. Captures the resolver-loop pattern duplicated across five families (llm, claude_tool, mcp, exec, tts) in rust/src/runtime/mod.rs so the generic dispatcher can read adapter_families + behavior_kinds + the meta-shape fixtures and produce one specialized resolver per family. Sibling Futamura target to diagnostic_validator_meta_shape (Ruby specializers) and hecksagon_parser_shape (Rust parsers). Pairs with i557 part 2 — when the meta-shape lands and generates the resolvers, framework_registry.seed_kernel_hooks retires too.'
links:
  - i557 — framework_registry / part 2 (retires hardcoded :claude_tool shortcut)
  - i569 — :web_tool adapter family (pending resolver)
---

# i651 — DispatchMetaShape : the meta-shape that retires the runtime resolver duplication

## Chris's seed

> the Rust runtime has imperative branches per command kind in
> `rust/src/runtime/` and the dispatcher routes between them. the
> goal of the Futamura arc is that the dispatcher reads the
> bluebook IR and dispatches GENERICALLY — no command-aware Rust
> code.

## What this card delivers tonight

Design only — the bluebook + fixtures + behaviors smoke for the
meta-shape that ENABLES the retirement. The retirement itself (a
multi-week arc) is named below as a follow-up sequence.

Files shipped on `feat/dispatch-meta-shape-design` :

- `codegen/dispatch_meta_shape_shape/dispatch_meta_shape.bluebook`
- `codegen/dispatch_meta_shape_shape/fixtures/dispatch_meta_shape.fixtures`
- `codegen/dispatch_meta_shape_shape/dispatch_meta_shape.behaviors`
- `codegen/dispatch_meta_shape_shape/snippets/` (intentionally empty)
- this inbox card

## The duplication that retires

`rust/src/runtime/mod.rs` carries FIVE near-identical resolver
loops, one per dispatcher family :

| Resolver fn (mod.rs)              | Dispatcher module           | Family       | Behavior kind          |
|-----------------------------------|------------------------------|--------------|-------------------------|
| `resolve_llm_adapters`            | `llm_dispatcher`            | `llm`        | `invoke_llm`            |
| `resolve_claude_tool_adapters`    | `claude_tool_dispatcher`    | `claude_tool` | `invoke_claude_tool`    |
| `resolve_mcp_adapters`            | `mcp_dispatcher`            | `mcp`        | `invoke_mcp_tool`       |
| `resolve_exec_adapters`           | `exec_dispatcher`           | `exec`       | `invoke_exec`           |
| `resolve_tts_adapters`            | `tts_dispatcher`            | `tts`        | `render_text_to_audio`  |

Plus pending : `resolve_web_tool_adapters` (i569), an sms resolver
(stub today), and a rework of `resolve_compute_adapters`. Each
resolver is 60-180 LoC of glue that follows the same seven-step
shape :

1. Guard empty hecksagons / read debug env var
2. Build `target = "<aggregate>.<bare_command>"`
3. Collect matching adapters (from one of two sources)
4. Snapshot upstream aggregate state into a `HashMap<String,String>`
5. Overlay dispatch attrs (and optionally cross-aggregate state)
6. Fold the adapter instance's declared fields into the attrs
7. Call the dispatcher ; wire the response via cascade or
   fire-and-forget

The meta-shape captures THAT loop. The dispatcher bodies — ElevenLabs
HTTP, MCP stdio, shell spawn, Anthropic API — stay as family-specific
work because that's where each family's substance lives. What's
command-aware in the bad way is the nine copies of the same glue.

## Shape (three nested value_objects)

Mirrors the canonical meta-shape triple (RubyClass / RubyConstant /
RubyMethod, LineParser / LineDispatch / ParserHelper) :

### EmitResolver (the specializer entry point)

The root aggregate `DispatchMetaShape` carries one command,
`EmitResolver(family_name, output_rs)`, which is the eventual
specializer entry point. The body is the deferred work — for the
design ship, the command exists as contract so :

- The bluebook validates clean (`VALID — DispatchMetaShape (1 aggregates)`)
  instead of carrying the universal "no commands" complaint every
  other catalog-only meta-shape carries today.
- The `.behaviors` smoke has a real command to dispatch through
  (mirroring `EmitEmbeddedRs` on `EmbeddedBluebooks`).
- The retirement arc has a named entry point to fill in.

### DispatcherFamily (one row per resolver)

| field                  | meaning                                                     | example (tts)            |
|------------------------|-------------------------------------------------------------|---------------------------|
| `name`                 | family name from `framework/adapter_families/<name>.hecksagon` | `tts`                  |
| `dispatcher_module`    | the Rust module that holds the family-specific dispatch fn   | `tts_dispatcher`         |
| `dispatch_fn`          | the public fn the resolver calls                            | `dispatch` (llm uses `call`) |
| `behavior_kind`        | the `framework/behavior_kinds/<name>.hecksagon` this implements | `render_text_to_audio` |
| `adapter_source`       | `typed_list` \| `io_adapters`                              | `typed_list`             |
| `response_wire`        | `cascade_via_result_into` \| `cascade_via_response_into` \| `fire_and_forget` | `fire_and_forget` |
| `cross_aggregate_attrs` | snapshot every aggregate's state into attrs (today only `llm`) | `false`              |
| `cycle_guard`          | track fired-adapter names for cascade-of-cascade (today only `llm`) | `false`           |
| `debug_env_var`        | env var that toggles the resolver's debug trace             | `HECKS_DEBUG_TTS`        |
| `log_label`            | stdout audit-line label                                     | `tts`                    |
| `order`                | emission order in the runtime's post-dispatch sequence      | `6`                      |

### DispatcherFieldMap (N rows per family)

Names the adapter fields the resolver folds into the attrs the
dispatcher reads. For `io_adapters` families, these come from the
`.options` map ; for `typed_list` families, they come from named
struct fields on the typed `Adapter` (e.g. `TtsAdapter.voice_id`).

### CascadePayloadField (N rows per family)

Names the fields the resolver lifts off the dispatcher's result
and lands on the cascade dispatch. `fire_and_forget` families have
zero rows — that IS the contract.

## The two adapter_source sub-patterns

The most consequential variation point. Today's resolvers split :

- **`typed_list`** — walks `hecksagons[*].<family>_adapters` (one
  of `llm_adapters` / `compute_adapters` / `tts_adapters`). The
  parser already lifts these into named struct fields ; matching
  uses `effective_trigger() == target`. Cleaner.
- **`io_adapters`** — walks `hecksagons[*].io_adapters` filtered
  by `kind == family_name`. The parser leaves fields in an
  `options: HashMap<String,String>` ; the resolver strips quotes
  and colons from string values before folding. Looser.

**Design decision (option (a))**. The shape carries both as a
discriminator. A future arc may force one of :

- (b) typed_list only — migrate `:claude_tool` / `:exec` / `:mcp`
  to typed `ClaudeToolAdapter` / `ExecAdapter` / `McpAdapter`
  structs in the IR. Cleaner final state ; requires parser
  changes in `hecksagon_parser_shape`.
- (c) io_adapters only — dissolve `LlmAdapter` / `ComputeAdapter`
  / `TtsAdapter` into the generic `IoAdapter`. Also cleaner ;
  loses some compile-time guarantees.

Option (a) is the safe shape for the design card. The follow-up arc
can pick (b) or (c) without restructuring the meta-shape — just
deleting one branch of the `adapter_source` discriminator.

## Worked example : the canonical five families

Fixtures ship with five `DispatcherFamily` rows that cover both
`adapter_source` variants and all three `response_wire` variants :

| family      | adapter_source | response_wire                  | wired today via                  |
|-------------|----------------|---------------------------------|-----------------------------------|
| llm         | typed_list     | cascade_via_response_into       | `resolve_llm_adapters`            |
| claude_tool | io_adapters    | cascade_via_result_into         | `resolve_claude_tool_adapters`    |
| mcp         | io_adapters    | cascade_via_result_into         | `resolve_mcp_adapters`            |
| exec        | io_adapters    | cascade_via_result_into         | `resolve_exec_adapters`           |
| tts         | typed_list     | fire_and_forget                 | `resolve_tts_adapters`            |

That's enough to lock down every variation point. The four pending
families (web_tool, sms, compute, future) land as additional rows ;
nothing in the shape changes.

## What retires when fully landed (dependency order)

This is the full Futamura sequence — NOT in scope tonight ; named so
the design card is a useful map for the multi-week arc.

1. **Specializer that consumes `DispatchMetaShape`** — analogous to
   the parser-shape and validator-shape specializers. Reads the
   fixtures, emits one resolver fn per `DispatcherFamily` row from a
   shared `.rs.frag` template (the snippets/ directory fills in here).
2. **First retirement : tts** — the smallest resolver and freshest
   in mind. Generate `resolve_tts_adapters`, byte-compare against
   the current hand-written version, swap once the diff is empty.
3. **Second : exec** (smallest io_adapters-source resolver, no
   cross-aggregate / no cycle-guard ; fast confidence on the
   io_adapters arm).
4. **Third + fourth : claude_tool + mcp** (the two largest
   io_adapters resolvers ; covers the result_into cascade path).
5. **Fifth : llm** (the most-special resolver — `cross_aggregate_attrs`
   + `cycle_guard` + cascade_via_response_into all live here). Once
   llm regenerates byte-identical, the generic resolver covers every
   variation.
6. **Retire `seed_kernel_hooks`** — `framework_registry` no longer
   needs its hand-registered table because the specializer registers
   every behavior_kind's hook from the same fixtures. The
   `antibody-exempt` markers in
   `claude_tool_dispatcher`, `mcp_dispatcher`, `sms_dispatcher`,
   `tts_dispatcher`, `llm_dispatcher` come off in lockstep — they
   were exempted only because they were command-aware ; once the
   command-awareness lives in the shape, the marker no longer applies.

Total expected delta : ~600-800 LoC removed from
`rust/src/runtime/mod.rs` (the five resolver bodies) plus the
`seed_kernel_hooks` table plus the per-dispatcher antibody markers.

## Open questions for the retirement arc

- **Compute resolver shape.** `resolve_compute_adapters` was
  glanced at, not read in full ; before generating it, confirm it
  matches `cascade_via_response_into` + `cross_aggregate_attrs:
  false` + `cycle_guard: false` (sibling of LLM minus the
  cross-aggregate / cycle behavior).
- **Web_tool resolver wire.** i569 is on a worktree branch ; when
  it lands, the family's `response_wire` may surface a new variant
  (it's currently NOT wired into `Runtime::dispatch` per the
  module's own doc). Land it as cascade_via_result_into and let the
  shape grow if the worktree diverges.
- **Sms dispatcher.** Today's stub returns `ok: false` and is not
  wired into a resolver. When real Twilio integration lands, the
  family slots in as `io_adapters` + `cascade_via_result_into`
  (sibling of exec).

## Acceptance (tonight)

- [x] `codegen/dispatch_meta_shape_shape/dispatch_meta_shape.bluebook`
      exists and validates clean (`VALID — DispatchMetaShape (1
      aggregates)` — ahead of every other meta-shape under codegen/,
      which all carry the "no commands" complaint).
- [x] `codegen/dispatch_meta_shape_shape/fixtures/dispatch_meta_shape.fixtures`
      carries five `DispatcherFamily` rows (one per existing resolver)
      plus the field-map and cascade-payload rows.
- [x] `codegen/dispatch_meta_shape_shape/dispatch_meta_shape.behaviors`
      has at least one smoke test (EmitResolver tuple plumb-through
      for tts — 1/1 passing).
- [x] `codegen/dispatch_meta_shape_shape/snippets/` exists (empty
      bar a `.gitkeep` explaining the deferred work).
- [x] Inbox card filed.
- [ ] Pre-push gate green (verified on push).
- [ ] Push to `feat/dispatch-meta-shape-design` ; do NOT merge to
      main.

## Boundaries respected tonight

- Did not modify any existing dispatcher (`tts_dispatcher`,
  `llm_dispatcher`, `claude_tool_dispatcher`, `mcp_dispatcher`,
  `exec_dispatcher`, `sms_dispatcher`, `web_tool_dispatcher`,
  `shell_dispatcher`, `compute_dispatcher`).
- Did not touch the Hecksagon parser (sibling agent owns that).
- Read-only on every other production runtime file
  (`framework_registry.rs`, `command_dispatch.rs`, `mod.rs`).

## Method note

This is DESIGN. The bluebook + fixtures describe the meta-shape ;
the actual specializer that consumes them is the first item in the
retirement arc above. Don't conflate the two.
