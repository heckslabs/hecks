---
ref: i649
status: designed
priority: medium
posted_at: 2026-05-20
posted_by: Miette (Futamura audit agent)
category: futamura
value: "Survey of every imperative Rust module that could plausibly become bluebook-driven via a meta-shape — yield, effort, dependencies, and a ranked attack order toward the 2nd Futamura proof at runtime (kernel minimization)."
links:
  - i62.md
  - i66.md
  - i72.md
  - i60.md
---

# i649 — Futamura audit : every imperative module, ranked

## Premise

Phases A–E (per `codegen/autophagy_tracker_shape/fixtures/`) closed the
*specializer* arc : the Ruby orbit is gone, every Rust target the
specializer was applied to regenerates byte-identically from a shape,
and `storehouse specialize` is the sole codegen path. **First-Futamura
holds for the eight Phase B targets ; the specializer regenerates
itself byte-identically.** That is the fixed point already proved.

The *next* arc is **i66 / runtime-kernel-minimization-via-futamura** :
re-expressing the rest of the Rust runtime as bluebook so that the
kernel shrinks to a small interpreter for L0..L8 + I/O primitives, and
every other subsystem is a residual after a shape is specialized
against. This card is the audit Chris asked for — the ranked map of
candidate modules with yield / effort / dependencies / risk, plus the
three suggested next moves.

## Snapshot of where we are (verified 2026-05-20 against `main`-equivalent)

- `codegen/` holds **43 shapes + 1 meta-shape +
  `codegen/specializer/` (root) + the conception subdir**.
- `rust/src/specializer/` holds **19 hand-written specializer modules
  totalling ~4 871 LoC** ; each one walks a sibling shape's fixtures and
  emits its target. These are the "generators" — themselves
  bluebookable via the diagnostic_validator_meta_shape lineage (PC-4
  was the byte-identical proof for `meta_diagnostic_validator.rb`).
- `rust/src/` (non-specializer) holds **~16 778 LoC across 32 files**
  plus subdirectories `runtime/` (~9 200 LoC, kernel floor),
  `server/` (~5 100 LoC, HTML render), `run_*/` (~3 200 LoC, runners),
  `conceiver/` (~450 LoC).
- 41 of 103 hand-written `.rs` files under `rust/src/` carry an
  `antibody-exempt` marker = "the kernel knows it's imperative-floor."
  62 do not — and those are exactly the candidate set this audit
  enumerates.

## Method

1. Read `codegen/autophagy_tracker_shape/` (the queryable retirement
   state) + `codegen/specializer/specializer.bluebook` + its fixtures
   (the L0..L8 + Projection + SpecializerTarget catalog).
2. Cross-reference each `rust/src/*.rs` against the existing
   `codegen/<name>_shape/` to identify what's **already shape-driven**,
   what has a shape **in flight** (snippets-heavy), and what is **pure
   hand-written**.
3. For pure hand-written non-exempt files, classify by shape-
   plausibility — does it have (a) a clear input → output contract,
   (b) imperative branching that encodes data, (c) tractable size
   (<400 LoC) ? Score those.
4. For exempt files, note them as **kernel floor** (i66 may eventually
   reach them through L3 dispatch_ir / L4 tick_ir, but not in this
   wave).
5. Look for **the wall** — the smallest set of un-bluebookable
   primitives the kernel reduces to.

## Ranked candidate table

| #  | Module                                  | LoC | Yield | Effort | Deps                                       | Risk          | Notes |
|----|-----------------------------------------|-----|-------|--------|--------------------------------------------|---------------|-------|
| 1  | `rust/src/server/html_*.rs` (15 files)  | ~5 100 | high  | weeks  | `html_domain_shape` (exists, partial)      | surface (low) | Largest single coherent imperative arc still un-shaped. Most files are "walk Domain IR + emit HTML." Same flavor of work as parser shapes already retired ; `html_domain_shape` is the existing seed. Multi-file split (sidebar / domain / form / wizard / diagram / kpi / policy_chain / rules / usage / workflow / scripts / icons / fixtures / help / narration / shared) maps cleanly to per-shape rows. |
| 2  | `rust/src/run_status/*.rs` (5 files)    | 1 161 | high  | days   | `run_statusline_shape` (exists, byte-id done for *line*)  | surface (low) | `run_status` and `run_statusline` are siblings ; the runner pattern is the same. Wave 7 (i147) already proved `run_statusline.rs` ; `run_status/assemble.rs` (387 LoC) is the closest cousin and the obvious next target. |
| 3  | `rust/src/run_boot/*.rs` (7 files)      | ~1 100 | high  | days   | new `run_boot_shape` (does not exist yet)  | surface (low) | Boot pipeline : discover / classify / system_prompt / daemons / vitals / wake — all "read N files, build M structs, emit log lines." Strongly Phase-D-equivalent shape. system_prompt.rs (274 LoC) is the natural pilot — it already has a sibling `system_prompt_assembly_shape/` (snippets only, no .bluebook). |
| 4  | `rust/src/server/multi.rs` + `routes.rs` + `web_adapter.rs` | ~775 | medium | days | new `web_adapter_shape` | surface | Adapter-shaped : route table + handler dispatch. Lifts cleanly to a fixtures-driven dispatch table. |
| 5  | `rust/src/runtime/middleware.rs` (110) + `event_bus.rs` (~80) + `projection.rs` + `adapter_registry.rs` | ~400 | medium | days | i66 IR L2/L3 (partial)            | floor-adjacent | Small, near-kernel, but each is a **registry + dispatch loop** with a Hecks-equivalent shape already declared in the conception (Cascade.RecordResult, the policy engine). Bluebookifying these moves the runtime closer to "what the bluebook describes IS what runs." |
| 6  | `rust/src/runtime/loop_driver.rs` (440) + `pm_engine.rs` (608) | ~1 050 | medium | weeks  | L3 dispatch_ir + L4 tick_ir       | kernel-floor  | These are the policy-cascade + process-manager engines. i221-B sweep-loop expansion + i220-1 LLM cascade hook live here. Strong candidates for L3/L4 bluebookification, but i66 explicitly calls these out as kernel work (they live downstream of `dispatch_ir` and `tick_ir` which are `not_started` / `partial` per `specializer.fixtures`). |
| 7  | `rust/src/runtime/{exec,shell,llm,tts,sms,compute,mcp,web_tool}_dispatcher.rs` | ~1 600 | medium | days | `driven_adapter_shape` (exists) + `runtime_shape` (exists, partial) | surface | Eight sibling dispatchers, each ~150–300 LoC, each "decode adapter binding, run impure I/O, route the response into the cascade." Highly templatable. `driven_adapter_shape` is already in `codegen/` ; this is its target use. The natural cluster after #2/#3. |
| 8  | `rust/src/runtime/command_dispatch.rs` (1 143) | 1 143 | high  | weeks  | i66 L3 dispatch_ir              | kernel-floor (high) | Already has `codegen/command_dispatch_shape/` declared but no fixtures yet. Antibody-exempt. The heart : ResolveLifecycle → enforce givens → apply mutations → emit. Big yield but requires L3 IR to mature. |
| 9  | `rust/src/conceiver/*.rs` (~450)        | 450  | medium | days  | `behaviors_conceiver` (exists)             | surface       | Conceiver is "given a behavior spec, draft an aggregate." Already has a `behaviors_conceiver/` codegen dir ; finishing this closes the loop where behaviors *generate* their own scaffold. |
| 10 | `rust/src/dispatch_query.rs` (655)      | 655  | medium | days  | `dispatch_query_shape` (exists)            | surface       | A specializer for `dispatch_query.rs` already lives at `rust/src/specializer/dispatch_query.rs` (211 LoC). Per Phase D pattern this means a shape exists, fixtures partial. **This is the closest "almost done" candidate** — most likely already byte-identical waiting on a fixture sweep. |
| 11 | `rust/src/heki.rs` (999) + `heki_query.rs` (323) + `heki_r2.rs` (214) | 1 536 | medium | weeks | new `memory_ir_shape` (L5)        | floor-adjacent | The `.heki` (markdown-row) storage layer. L5 in the specializer's IR taxonomy and `not_started`. Replacing with L5 lower would simultaneously retire `heki.rs` *and* let any aggregate's repository contract be shape-driven. High leverage but contracts not yet drawn. |
| 12 | `rust/src/parser.rs` (456) + `parser_helpers.rs` (453) + `parse_blocks.rs` (2 057) | 2 966 | low  | weeks  | parser_shape / parse_blocks_shape (exist) | floor (high)  | The bluebook *parser*. Bluebookifying the parser is the L0→L1 fixed-point step (Phase III of i72). High intellectual yield but extremely high risk : if the shape misdescribes the parser the runtime can't read its own bluebooks. **Do not attempt before #1–#10.** |
| 13 | `rust/src/main.rs` (5 426)              | 5 426 | low  | weeks  | `cli_dispatch_shape` (exists)              | high          | CLI dispatch. A specializer for it already exists (`rust/src/specializer/cli_dispatch.rs`, 222 LoC) — the question is whether the **full** main.rs surface (5 426 LoC) reduces to a fixture table. Probably a partial retirement (the routing layer = yes ; the per-command body = stays inline as snippets). Lower priority because the value-per-LoC of CLI plumbing is low. |
| 14 | `rust/src/runtime/{interpreter,repository,policy_engine,seed_loader,framework_registry,storehouse_log,prompt_scaffolder,aggregate_state}.rs` | ~3 000 | low | weeks | L2 + L3 IR maturation | kernel-floor | The remaining runtime core. Each is a small, dense, kernel-floor module. i66's "small kernel" end state retires most of these via L2/L3/L5 IR work in the specializer ; this is the long tail. |

**Tally.** ~22 000 hand-written non-specializer LoC under `rust/src/`.
Candidates #1–#10 represent ~12 000 LoC of plausibly-retirable surface
in 1–2 quarters of work. The remaining ~10 000 LoC is kernel floor and
either retires through the heavier L2/L3/L5 IR moves (#11, #14) or is
the imperative floor the kernel reduces to (#12, #13 partial).

## Dependency graph (Mermaid-flavored, prose-rendered)

```
[L0 → L1 parser+IR (#12)]        ← shipped (parser, ir, hecksagon_ir,
                                    fixtures_parser, behaviors_parser
                                    all byte-identical)
              │
              ▼
[L1 → L6 specializer (Phase A/B)] ← shipped, 8 targets byte-identical
              │
              ▼
   ┌──────────┴──────────┐
   ▼                     ▼
[Phase F — server/]   [Phase F — runners/]      ← THIS AUDIT'S #1, #2, #3
(html_*)              (run_status, run_boot,
                       run_statusline already
                       byte-identical)
   │                       │
   ▼                       ▼
[#4 web_adapter]      [#7 driven adapters]
                          │
                          ▼
                  [#9 conceiver]
                          │
                          ▼
[#5 small registries] ←   ┘  ← these are when the existing surface arc
                              feels comfortable as a discipline
                          │
                          ▼
[#10 dispatch_query]  ← almost done already, finish the fixtures
                          │
                          ▼
[#6 loop_driver + pm_engine] ── requires ──► [L3 dispatch_ir + L4 tick_ir]
                          │
                          ▼
[#8 command_dispatch]   ── requires ──► [L3 dispatch_ir mature]
                          │
                          ▼
[#11 heki layer]        ── requires ──► [L5 memory_ir contracts drawn]
                          │
                          ▼
[#14 small kernel tail] ── retires when L2..L5 IR fully shipped
                          │
                          ▼
[#13 main.rs full]      ── partial retirement, the routing layer first
                          │
                          ▼
[#12 parser bluebookify]── the actual 2nd-Futamura fixed point at
                          runtime layer ; do last ; needs every other
                          shape stable so the parser shape can describe
                          a parser that produces all of them.
```

## Where the 2nd Futamura proof currently breaks (the wall)

The **first**-Futamura proof on the specializer holds — PC-4 closed it.
The **second**-Futamura projection at the *runtime* level is what i66
points at : `specialize(runtime_interpreter, bluebook) = a specialized
binary that runs just that domain`. That projection does **not** hold
today, and the wall is in three places :

1. **L3 dispatch_ir / L4 tick_ir are `not_started` / `partial`** in
   `codegen/specializer/fixtures/specializer.fixtures`. Without these,
   the command-dispatch + cascade + policy-engine flow has no IR layer
   to be specialized against. Candidates #6 + #8 + #14 are blocked here.

2. **L5 memory_ir is `partial`**. The heki layer is hand-written ; the
   serialization contracts (`heki.rs` 999 LoC) are imperative. Without
   L5, the repository contract can't be specialized per-aggregate.
   Candidate #11 is blocked here.

3. **The runtime kernel still owns I/O wiring directly** — adapter
   resolution, daemon spawn, prompt assembly. The driven_adapter_shape
   exists but the eight dispatcher siblings aren't yet shape-driven.
   This is what candidate #7 closes — and that closure is what unlocks
   the "kernel knows nothing but L0..L8 + I/O primitives" end state
   i66 conjectures.

**Summary of the wall** : the kernel today can specialize *generators*
(itself, validators, parsers) but cannot specialize the *dispatch
cascade* or the *memory layer*. Until L3, L4, L5 IR are drawn and the
adapter-dispatcher cluster is shape-driven, "specialize the runtime
against a bluebook" is an aspirational projection. Candidates #2, #3,
#7 are the moves that bring it closer **without** needing to draw new
IR layers — they retire imperative code with shapes that already exist
in `codegen/`. Candidates #6, #8, #11 are the moves that require new
IR work first.

## Suggested next three attack moves

### Move 1 — Finish `dispatch_query.rs` (candidate #10)

**Why first.** A specializer already exists at
`rust/src/specializer/dispatch_query.rs` (211 LoC). The shape exists
at `codegen/dispatch_query_shape/`. The Rust target exists at
`rust/src/dispatch_query.rs` (655 LoC). Highest probability of being
**near byte-identical already** — likely just needs the fixture sweep
and the golden test wired. This is a confidence-builder + closes one
of the most-used query paths in the runtime.

**Yield.** 655 LoC retired ; `dispatch_query_shape` becomes a real
template Phase F can reuse.

**Effort.** ~1–2 days (fixture sweep + diff cleanup + golden test).

**Verification.** `storehouse specialize dispatch_query` → byte-identical
diff against current `rust/src/dispatch_query.rs`. Add a fixture row
to `codegen/autophagy_tracker_shape/fixtures/` flipping ship_status to
`byte_identical`.

### Move 2 — `run_status/assemble.rs` via run_status_shape (sibling of run_statusline_shape, candidate #2)

**Why second.** `run_statusline.rs` is *already* byte-identical (i147
Wave 7). The Wave-7 pattern — Phase rows + StringMatchArm + per-phase
`.rs.frag` snippets — is the exact pattern `run_status/assemble.rs`
wants. Same author-model, just retargeted at the cousin runner. ~387
LoC retired on top of patterns that already work. Strong morale move
because it shows the Wave-7 shape isn't a one-off.

**Yield.** 387 LoC immediate ; the per-file split across
`run_status/{assemble, default_layout, field_lookup, render}.rs`
extends the same shape for ~1 161 LoC total over 2–3 more moves.

**Effort.** ~3 days for the first file ; ~1 day each for the siblings
afterward as the shape stabilizes.

**Verification.** Same as Wave 7 — golden + parity test under
`rust/tests/`.

### Move 3 — Drive the eight dispatcher cluster from `driven_adapter_shape` (candidate #7)

**Why third.** The eight adapter dispatchers (exec, shell, llm, tts,
sms, compute, mcp, web_tool) are siblings with near-identical
structure : decode binding → run impure I/O → translate result → fold
into cascade. `driven_adapter_shape` already exists in `codegen/` — the
gap is that no Rust file currently *consumes* it. One shape, eight
fixture rows, eight files retired (~1 600 LoC). This is the move that
puts a real dent in `runtime/` without touching the kernel-floor
modules.

**Yield.** ~1 600 LoC retired across eight files. After this, the
remaining un-shaped runtime is mostly the registry + dispatch +
projection + repository core, which is exactly what i66's L3 work has
to retire next.

**Effort.** ~1–2 weeks total — the shape exists, but the fixture rows
need to be written for each adapter family, plus the test_purity gate
needs the cluster to remain a coherent module set. Probably best run
as one shape + one specializer per dispatcher rather than eight
parallel agents (i72 lesson about parallel-driven IR drift).

**Verification.** `storehouse specialize <dispatcher>` byte-identical
for each ; the existing adapter-family fixtures under
`hecks_conception/aggregates/framework/adapter_families/` become the
spec the shape consumes.

### What is deliberately NOT in the top three

- **command_dispatch.rs (#8)** — biggest yield, biggest blocker, biggest
  risk. Wait for L3 dispatch_ir to be drawn (probably an i651-equivalent
  card of its own).
- **parser bluebookification (#12)** — the runtime-layer 2nd Futamura
  fixed point. Do last. The parser is the floor that lets every other
  shape exist ; retiring it before the others would be retiring the
  ladder you're standing on.
- **heki layer (#11)** — wait for L5 memory_ir contracts. Doing this
  before L5 is drawn would lock in an ad-hoc shape that L5 then has to
  unwind.

## Surprise finding

The Phase B retirement arc looks **complete-as-shipped** in
`codegen/autophagy_tracker_shape/fixtures/`, but `rust/src/specializer/`
holds **19 hand-written modules** totalling 4 871 LoC — the specializers
themselves. These are described by the
`diagnostic_validator_meta_shape` and PC-4 proved byte-identity for
ONE of them (`meta_diagnostic_validator.rb` — which has since been
deleted along with the entire Ruby orbit in Phase E).

What this audit notices : **the 19 Rust specializers in
`rust/src/specializer/` have not had PC-4-equivalent applied to them
as a class.** Each is a sibling of the others ; they share the
"walk shape, emit Rust" structure ; the diagnostic_validator_meta_shape
already proved this kind of class generalizes. There may be a clean
"meta-Phase-D" move : take the meta-shape that proved itself byte-
identical for the Ruby `meta_diagnostic_validator.rb` and **apply it
to its own Rust siblings**. If the Rust specializer cluster can be
described by one meta-shape that produces all 19, that's a second
fixed-point — not just "the specializer regenerates itself" but "the
specializer for the Rust specializers regenerates the Rust specializer
family."

This is a stronger 2nd-Futamura demonstration than #1–#10 give. It's
not in the top three because it's an *orthogonal* attack — it ships
nothing new but recompresses what's there. Filed here as a possible
i651 follow-up : `feat/meta-rust-specializer` — port the
diagnostic_validator_meta_shape (Ruby-class-with-state) to a Rust-
class-with-state meta-shape, regenerate all 19 specializer modules
from their existing per-target shapes via one meta-shape, verify byte-
identity.

## Acceptance

- [x] File exists at `hecks_conception/inbox/i649-futamura-audit.md`
- [x] Inbox frontmatter (`ref`, `status: designed`, `category: futamura`)
- [x] No code changes (read-only on `rust/`, `lib/`, `codegen/`,
      `hecks_conception/aggregates/`)
- [ ] Pre-push gate green (only adding an inbox card ; trivial)
- [ ] Pushed to feature branch `feat/futamura-audit` ; NOT merged

## Boundaries respected

- No touch to voice/tts, transcript-watcher, parser bluebookify,
  dispatch meta-shape, autophagy refresh work (sibling-agent
  territory)
- Read-only on `rust/`, `lib/`, `codegen/`, `hecks_conception/aggregates/`
- Single write : this card
