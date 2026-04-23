# i51 — Futamura projections: the Rust autophagy arc

Source: inbox `i51` + tonight's conversation with Chris, 2026-04-23.

> **The framing is Futamura's three projections** (1971), not a bespoke
> "stack of layers" invention. Naming it correctly matters — the theory
> is 50 years old, the literature is deep, and misnaming it as
> "Fukushima layers" or "fujiyama projections" would obscure what we're
> actually doing.

## §1 — Futamura in one page

Let `I` be an interpreter — a program that takes a source `P` and input
`D` and returns `I(P, D)`. Let `mix` be a *partial evaluator* — a
program that takes another program and some of its inputs, and returns
a specialized version with those inputs baked in.

### The three projections

**1st Futamura**: `mix(I, P)` produces `P'` — a compiled version of `P`.
  You specialized the interpreter on the source. The output runs at
  compiled speed for that one program. No recompile needed; partial
  evaluation did it.

**2nd Futamura**: `mix(mix, I)` produces a compiler.
  You specialized the partial evaluator on the interpreter. The output
  is a program that, given any `P`, returns compiled `P'`. You built a
  compiler by specializing `mix` — you didn't hand-write one.

**3rd Futamura**: `mix(mix, mix)` produces a compiler generator.
  You specialized `mix` on itself. The output, given any interpreter,
  returns a compiler for that interpreter's language. Compiler-
  generating compiler.

### What we are doing

The Hecks runtime IS an interpreter. `hecks_life` takes a bluebook
(program) and heki state (input) and returns new heki state (output).
That is `I(P, D)`.

**Our mission:** apply Futamura to replace `hecks_life`'s hand-written
Rust with generated Rust, and eventually with a self-hosting system
where the compiler itself is bluebook-described.

## §2 — Where we already are

### Ruby autophagy — 1st Futamura, shipped.

`docs/usage/binary_compiler.md` describes it. `hecks compile` produces
`hecks_v0` — a single-file dependency-free Ruby script that is Hecks
specialized to its own source. The pipeline:

1. Prism AST analysis over `lib/`
2. File-level dependency graph
3. Topological sort
4. Source transform (strip requires, expand compact-class syntax)
5. Bundle write

This is a partial evaluator for the Ruby interpreter, specialized on
the Hecks Ruby source. A 1st-Futamura success. **We've done this
once.** The pattern is proven; only the language target changes for
i51.

### Canonical IR — the interpreter is already factored.

`hecks_life/src/dump.rs` + `spec/parity/canonical_ir.rb` already produce
a shared JSON IR from both Ruby and Rust parsers. The interpreter's
internal representation is stable and cross-language. This is what
`mix` will specialize against. The Fukushima-chain layers from an
earlier draft of this plan describe those internals — not a new
invention, just a factoring.

## §3 — The interpreter, factored

Partial evaluation works layer by layer. `hecks_life`'s interpreter
already has these internal stages; naming them explicitly lets us
specialize one at a time rather than all at once.

| Layer | Name            | Contents                                                                       |
|-------|-----------------|--------------------------------------------------------------------------------|
| L0    | `bluebook`      | Source (the five DSLs in `hecks_conception/`)                                  |
| L1    | `canonical_ir`  | Normalized JSON IR (shipped: `dump.rs` + `canonical_ir.rb`)                    |
| L2    | `flow_ir`       | Command graph: commands → events → policies → triggers, per aggregate          |
| L3    | `dispatch_ir`   | Command bus lowered: middleware, guards, mutations, emissions, persistence     |
| L4    | `tick_ir`       | Body-cycle shape: which commands fire on mindstream/heart/consciousness ticks  |
| L5    | `memory_ir`     | Heki I/O lowered: paths, append/upsert, serialization contracts                |
| L6    | `rust_ir`       | Rust-specific: module structure, ownership, lifetimes, Serde derives, traits   |
| L7    | `rust_source`   | Emitted .rs files, rustfmt'd, compiled via `cargo build`                       |
| L8    | `rust_binary`   | The artifact. Terminus.                                                        |

Each layer is a pure function of the one above. Each is describable as
a bluebook (per i36 projection pattern — `reads_from`/`returns`). The
composition is the interpreter. Partial-evaluating at any level
produces a specialized form of everything below.

## §4 — Phases

### Phase A — first Futamura on one module. Proof.

**Goal**: generate `hecks_life/src/validator.rs` from its bluebook
description, byte-equivalent to the hand-written source.

**Steps**:

1. Describe `validator.rs`'s semantics as a bluebook — each validation
   rule as an aggregate with a command whose guards and emissions
   encode the check.
2. Write the first real bluebook→Rust specializer: takes validator's
   L2/L3/L6 description, emits `.rs` text.
3. Diff generated output against `hecks_life/src/validator.rs` — target
   byte-identity after rustfmt normalization.
4. Replace the hand-written file; re-run `cargo test`; re-run parity.
   Everything green means the 1st Futamura worked for this module.

**Scope**: ~500 LoC bluebook + ~300 LoC specializer. 1 week.
**Deliverable**: one retired hand-written Rust file + a reusable specializer.

### Phase B — first Futamura across the runtime. Coverage.

Module by module. Each migration retires a piece of hand-written Rust
and extends the specializer's coverage. Ordering follows Fukushima-
layer difficulty — the most declarative modules first:

1. `validator.rs` + `validator_warnings.rs` (Phase A's target)
2. `fixtures_parser.rs`, `behaviors_parser.rs`, `hecksagon_parser.rs`
3. `dump.rs` (the canonical-IR serializer — easy, almost declarative)
4. Heki I/O modules (`heki/*.rs`)
5. Runtime primitives (command bus, cascade, adapter dispatch)
6. CLI + main.rs subcommand dispatch
7. The parsers themselves (hardest, self-referential — the bluebook
   interpreter that reads bluebooks is specialized on its own source)

**Scope**: ~6 months at one-module-per-week.
**Deliverable**: hand-written Rust in `hecks_life/src/` progressively empties.

### Phase C — second Futamura. Compiler-as-bluebook.

**Goal**: the specializer itself is bluebook-described. `mix(mix, I)`.

By the end of Phase B we have a specializer that — given any
bluebook — produces its Rust. That specializer is still hand-written
Rust at Phase B's end. Phase C lifts it:

1. Describe the specializer's semantics as a bluebook (it's a program
   that walks L1→L7; each walk is an i36-style projection).
2. Apply the specializer to itself. Output: a specializer compiled
   into Rust, byte-equivalent to the hand-written one.
3. Verify fixed point: `binary_N` compiles the specializer bluebook →
   `binary_(N+1)`; `binary_N == binary_(N+1)`.

When step 3 holds, **we are self-hosting**. The compiler is bluebook-
described. The Rust is a derived artifact. The repo's ground truth is
the five DSLs.

**Scope**: 2-4 weeks after Phase B.
**Deliverable**: the self-hosting birthday.

### Phase D — (deferred, speculative) third Futamura.

`mix(mix, mix)` = compiler generator. Useful if we ever target a
second language (Go, WASM, an interpreter in another runtime). Not
in scope for i51. Filed as a future inbox item when we care.

## §5 — Self-hosting: bootstrap vs fixed-point

These are different bars:

- **Bootstrapping**: `binary_N` can compile the sources to produce
  `binary_(N+1)` that runs correctly. Timestamps, symbol order, and
  incidental codegen may differ. Output is functionally equivalent.
- **Self-hosting (strict)**: `binary_N == binary_(N+1)` bit-identical.
  Requires deterministic codegen — stable sort orders, fixed timestamps,
  reproducible build. Stronger property.

i51 targets bootstrapping first, then tightens to strict self-hosting.
The gap between them is determinism work (~1 week after Phase C).

## §6 — Load-bearing constraints

### C1: the heartbeat must survive (i54)

The binary being replaced is running `hecks_life`, which runs Miette's
body cycles. The generation pipeline cannot stop the tick. Required:

- Phase A/B/C all run in a worker, not in the live runtime.
- The current binary keeps beating while the new one generates.
- Hot-swap on artifact readiness: the next mindstream tick picks up the
  new binary from `target/release/hecks-life` atomically.
- Regression test: run a sleep cycle during a full projection pass;
  `heartbeat.heki` `.cycle` monotonically increases at ≥1 per second
  throughout. If the tick stalls, the projection is wrong.

### C2: parity-testable at every layer

Each specialized output must have a parity contract. For Phase A's
validator.rs: generated vs hand-written, byte-identical after format
normalization. For Phase C's self-hosted compiler: `binary_N ==
binary_(N+1)` hash equivalence.

### C3: does not ship rustc

The binary is not a self-contained compiler in the "includes rustc"
sense. It ships:

- The bluebook interpreter (what hecks_life already is)
- The Fukushima-layer projection bluebooks embedded as data
- A `self-compile` subcommand that writes Rust to `target/src/` and
  hands off to `cargo build`

Cargo is the only external dependency. This is fine — cargo is stable,
ubiquitous, and orthogonal to what we're building.

### C4: each specializer is a bluebook capability

Per i36 pattern: `query "Lower" do reads_from "bluebook" returns
"canonical_ir" end`. The projections are first-class Hecks capabilities,
not opaque Rust. Debuggable, introspectable, testable the same way
every other aggregate is.

## §7 — Consumer audit — what retires when this ships

At Phase B end:

- `hecks_life/src/validator*.rs` — generated
- `hecks_life/src/fixtures_parser.rs`, `behaviors_parser.rs`,
  `hecksagon_parser.rs` — generated
- `hecks_life/src/dump.rs`, `canonical_ir.rb` — generated (canonical
  contract moves into the bluebook)
- `hecks_life/src/heki/*.rs` — generated
- `hecks_life/src/runtime/*.rs` (command bus, adapters, cascade) — generated
- `hecks_life/src/main.rs` (CLI) — generated
- `hecks_life/src/*_parser.rs` and parsers' IR — generated
- `lib/hecks/**/*.rb` — still Ruby, but increasingly a parallel
  specializer target (we could apply the same Futamura treatment to
  the Ruby side as an optional Phase E)

At Phase C end:

- The specializer itself is generated. Self-hosting terminus.

## §8 — Relationships to other arcs

- **i26** (self-compile loop) — architectural parent. i51 is i26's
  concrete execution plan. When i51 lands, i26 closes.
- **i36** (computed views) — each Futamura projection is an i36-
  shaped bluebook query. The patterns converge.
- **i42** (catalog-dialect) + **i43** (cross-bluebook behaviors) — both
  needed before i51 Phase A, because the bluebook-described projections
  will span multiple bluebooks and reference catalog-only schemas.
- **i54** (heartbeat preservation) — a constraint on i51, carved out as
  its own item because it's load-bearing across all phases.
- **i30** (differential fuzzer) — extend to fuzz the projection chain:
  given a random legal bluebook, does the specialized Rust produce
  identical behavior to the interpreted Rust?
- **i55** (forget_bias signal pruning) + **i56** (prompt template) —
  surfaced during planning but independent of i51.

## §9 — Commit sequence for Phase A

The whole arc is long; Phase A is the concrete next step.

1. `feat(capabilities/specializer): value-objects for L1-L6 IR` — ~150 LoC
2. `feat(specializer): L1 → L2 projection for validator.rs description` — ~200 LoC
3. `feat(specializer): L2 → L3 projection (dispatch lowering)` — ~200 LoC
4. `feat(specializer): L6 → L7 Rust emission for validator shape` — ~300 LoC
5. `test(specializer): byte-identity vs hand-written validator.rs` — golden
6. `chore(runtime): replace validator.rs with generated file` — commit the generated artifact; keep parallel until confidence is high
7. `docs: Phase A retrospective` — what we learned; what Phase B changes

Phase A totals ~900 LoC new + retires ~550 LoC hand-written. Small net
growth. The growth is amortized across future phases.

## §10 — Risks

### R1 — determinism debt (addressed in Phase C)

Bit-identical self-hosting requires stable sort orders, fixed
timestamps, and deterministic codegen. The first few phases will
likely not produce byte-identical output; we track this as an
acknowledged gap and close it before calling ourselves self-hosting.

### R2 — interpreter churn during migration

If `hecks_life/src/*.rs` is being actively edited while we're also
generating it, we'll fight merges. Mitigation: freeze the module being
migrated for the duration of its Phase B step. One module per week.
Not concurrent with other Rust work on that module.

### R3 — the bluebook describing the compiler describes itself

When Phase C tries to apply the specializer to its own source, the
specializer bluebook references itself. Classic bootstrap chicken/egg.
Mitigation: the standard solution — freeze a "stage 0" specializer in
Rust, use it to compile the bluebook-described specializer, retire
stage 0. Then the stage-1 specializer compiled from its own bluebook is
byte-equivalent to stage 0 within a few iterations.

### R4 — Rust codegen complexity

Generating idiomatic Rust with lifetimes, ownership, and trait
dispatch is not trivial. The first Phase B modules (validator, parsers)
are mostly pure-data transforms where codegen is straightforward. The
later modules (runtime primitives, command bus) will require real
codegen sophistication. Budget accordingly.

### R5 — scope creep toward Phase D

The third Futamura is tempting — compiler-generator gives us multi-
target (Go, WASM). Keep i51 to Phases A-C. Phase D is a future arc.

## §11 — Key files

### New (Phase A)
- `hecks_conception/capabilities/specializer/specializer.bluebook`
- `hecks_conception/capabilities/specializer/specializer.behaviors`
- `hecks_conception/capabilities/specializer/specializer.hecksagon`
- `hecks_conception/capabilities/specializer/fixtures/specializer.fixtures`
- `hecks_conception/aggregates/fixtures/validator_shape.fixtures` (validator's L2+L6 description)
- `hecks_life/tests/specializer_golden_test.rs`

### Modified (Phase A)
- `hecks_life/src/validator.rs` — becomes generated artifact
- `hecks_life/src/validator_warnings.rs` — same
- `hecks_life/src/main.rs` — gains `self-compile` subcommand

### Reused (do not modify)
- `hecks_life/src/parser.rs`, `dump.rs`, canonical IR
- `docs/usage/binary_compiler.md` — Ruby precedent, reference

## §12 — Key decisions locked in

1. **Partial evaluation, not bespoke compilation.** The theory is
   Futamura's. The vocabulary we use is *mix*, *specialize*, *1st/2nd/3rd
   projection* — not ad-hoc "lowering stages."
2. **Bluebook-described projections.** Each specializer is an i36-style
   capability, not opaque Rust. Debuggable as code.
3. **Heartbeat preservation is non-negotiable.** i54 is load-bearing.
   Any projection that stops the tick is wrong by construction.
4. **Bootstrap before strict self-hosting.** We'll hit functional
   equivalence first, bit-identical second. Both are milestones; only
   the second closes i51.
5. **Rustc stays outside.** The binary ships a bluebook interpreter +
   projection bluebooks + a `self-compile` subcommand that hands to
   cargo. Not a rustc replacement.

*Voilà. Le plan. We start with Phase A — validator.rs as the first
Futamura proof — when you say go.*
