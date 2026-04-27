---
title: "Futamura Across a DDD Runtime: L0–L8 Factoring, Specialiser-as-Capability, and a Shipped Fixed Point"
authors: "Chris Young"
version: "paper/prior_use-v1-2026-04-24"
commit: "c4a903f3"
date: 2026-04-24
---

# Futamura Across a DDD Runtime

## L0–L8 Factoring, Specialiser-as-Capability, and a Shipped Fixed Point

**Version:** `paper/prior_use-v1-2026-04-24`
**Repository commit at time of writing:** `c4a903f3`
**Author:** Chris Young

## Abstract

We report the application of Futamura-style partial evaluation to the
runtime of a Domain-Driven Design (DDD) compiler, Hecks. The runtime is
factored into nine IR layers (L0–L8) declared as data; a partial evaluator
is wired as a hexagonal shell adapter, making the specialiser itself a
capability of the framework rather than a build-system artifact outside it.
Five phases are reported: Phase A retires a hand-written Rust validator
with a byte-identical generated file; Phase B extends the retirement to
additional modules; Phase C exhibits a fixed point
($\text{binary}_N \equiv \text{binary}_{N+1}$) via a meta-specialiser that
regenerates its own checkers; Phase D ports the Ruby specialiser to Rust
and demonstrates cross-language byte-identity; Phase E deletes the Ruby
specialiser entirely, collapsing the two-runtime framing to
one-runtime-plus-one-binding. The shipped state at commit `c4a903f3`
reports 100% autophagy completeness over 2,095 lines of in-scope code. We
place the techniques in the public record as prior art.

---

## §1 Introduction

Partial evaluation (Futamura, 1971; Jones, Gomard, and Sestoft, 1993)
relates interpreters to compilers through specialisation: given an
interpreter $I$ and a program $P$, a specialiser $\mathtt{mix}$ produces
$\mathtt{mix}(I, P)$, a program that computes what $I$ would compute on
input $P$ alone. The three Futamura projections compose this machinery
with itself to produce compilers and compiler generators from an
interpreter and a specialiser.

The standard settings for partial evaluation are general-purpose
languages — Scheme, SML, a subset of C — where the interpreter is the
host language's runtime and the specialiser has the full expressive power
of the host. Applying the machinery to the runtime of a *domain
compiler* — a framework whose interpreter is its own command bus, policy
engine, and event log rather than an arithmetic evaluator — is a
different setting.

This paper reports such an application. The Hecks framework's runtime is
a Rust binary that boots a domain from source (`.bluebook` + siblings),
validates it, wires adapters, registers a command bus, and serves HTTP
and MCP tool calls against the boot-time-registered aggregates. The
runtime is factored into nine IR layers; each layer is a declared data
artifact; each lowering is a declared projection; and the specialiser
that realises the projections is itself a Hecks capability, dispatched
through the framework's command bus.

The work is complete through Phase E: the Ruby specialiser that Phase A
produced has been replaced by a Rust specialiser that regenerates
byte-identical output and then deleted entirely. Phase C exhibited the
second-projection fixed point in the restricted form of a meta-specialiser
regenerating its own checkers.

### §1.1 Scope

This paper addresses the PL-audience framing of the Hecks autophagy arc.
It does not introduce DDD vocabulary; readers unfamiliar with aggregates,
commands, and policies should consult Paper 2 of this collection
(MCP-native framing) or the original DDD literature (Evans, 2003). It
does not describe the validator rules (Paper 1) or cascade lockdown
(Paper 4), except as downstream consumers of the specialiser.

### §1.2 Contribution

The contributions are:

1. A nine-layer factoring (L0–L8) of a DDD runtime into pure-function IR
   lowerings, declared as data in
   `hecks_conception/capabilities/specializer/specializer.bluebook`.
2. A *specialiser-as-capability* design: the partial evaluator is wired as
   a hexagonal shell adapter in
   `hecks_conception/capabilities/specializer/specializer.hecksagon`, so
   codegen is dispatched through the framework's command bus rather than
   invoked as a build script.
3. A shipped first-projection result: byte-identical regeneration of
   `hecks_life/src/validator.rs` from a shape-only declaration, with a
   golden test.
4. A shipped second-projection fixed point (restricted form): a
   meta-specialiser regenerates its own generator, producing a
   byte-identical binary over two iterations.
5. A shipped cross-language specialiser port: the Ruby specialiser is
   replaced by a Rust specialiser emitting byte-identical output; the
   Ruby specialiser is then deleted.
6. A distinction between *bootstrapping* and *strict self-hosting*
   (§6.5) aligned with the partial-evaluation literature.
7. A post-hoc framing note (§8): the arc was derived from DDD self-
   similarity pressure before being recognised as Futamura-shaped. The
   projections are a naming, not a generator.

### §1.3 Paper organisation

§2 fixes notation. §3 describes the L0–L8 factoring. §4 describes
projections as declared data. §5 describes the specialiser as a
capability. §6 describes Phases A through E as shipped. §7 compares to
classical partial-evaluation and self-hosting work. §8 reflects on the
role of the formal framing. §9 enumerates novel claims. §10 closes.

---

## §2 Notation

Let $I$ be an interpreter: a program that takes a source $P$ and an input
$D$ and returns $I(P, D)$. Let $\mathtt{mix}$ be a partial evaluator: a
program that takes another program and some of its inputs and returns a
specialised program with those inputs baked in. We write
$\mathtt{mix}(F, X)$ for the residual program that, given the rest of
$F$'s inputs, computes what $F$ would have computed given $X$ and those
inputs.

The three Futamura projections (Futamura, 1971; Jones *et al.*, 1993):

- **First projection.** $\mathtt{mix}(I, P) = P'$. Specialising an
  interpreter on a source program yields a compiled form of that
  program.
- **Second projection.** $\mathtt{mix}(\mathtt{mix}, I) = \mathtt{compiler}$.
  Specialising the specialiser on an interpreter yields a compiler for
  the interpreter's language.
- **Third projection.**
  $\mathtt{mix}(\mathtt{mix}, \mathtt{mix}) = \mathtt{compiler\_generator}$.
  Specialising the specialiser on itself yields a compiler generator:
  given any interpreter as input, it returns a compiler for that
  interpreter's language.

Paper 1 of this collection (and §8 of the original monolithic paper)
already notes that Hecks's `hecks compile` binary compiler — which
produces a zero-dependency single-file Ruby artifact of the framework —
is an instance of the first projection applied to the Ruby interpreter.
This paper focuses on the Rust runtime, where the projections are
applied module-by-module with strict byte-identity as the correctness
criterion.

---

## §3 The L0–L8 Factoring

The Rust interpreter's internal stages are promoted to first-class IR
layers. Each layer is a pure function of the layer above; composition
across all nine layers is the interpreter.

**Table 3.1 — The nine IR layers.**

| Layer | Name           | Contents                                                                    |
|-------|----------------|-----------------------------------------------------------------------------|
| L0    | `bluebook`     | Source — the five DSLs.                                                     |
| L1    | `canonical_ir` | Normalised JSON IR (`dump.rs` + `canonical_ir.rb`).                         |
| L2    | `flow_ir`      | Command graph per aggregate: commands → events → policies → triggers.      |
| L3    | `dispatch_ir`  | Command bus lowered: middleware, guards, mutations, emissions, persistence. |
| L4    | `tick_ir`      | Body-cycle shape (heartbeat-driven runtime schedule).                       |
| L5    | `memory_ir`    | Heki I/O lowered: paths, append/upsert, serialisation contracts.            |
| L6    | `rust_ir`      | Rust-specific: module structure, ownership, lifetimes, Serde derives.       |
| L7    | `rust_source` | Emitted `.rs` files, rustfmt-normalised, compiled via `cargo build`.        |
| L8    | `rust_binary` | The artifact.                                                               |

Each layer has a *reads-from* signature (the layer above) and a *returns*
signature (its output shape). The signatures are declared as data in
`hecks_conception/capabilities/specializer/specializer.bluebook`, via an
`IRLayer` aggregate and a `Projection` aggregate.

### §3.1 Why nine, not fewer

The nine layers partition the interpreter's work into pure functions
whose failure modes are distinct. L0 → L1 is parsing; a failure here is a
syntax error. L1 → L2 is cascade graph construction; a failure is a
structural error (unknown trigger, say). L2 → L3 is dispatch lowering; a
failure is a wiring error. L3 → L5 covers runtime plumbing. L5 → L6 is
the crossing into host-language specifics; a failure is a Rust-specific
code-gen error (ownership, lifetime). L7 → L8 is compilation; a failure is
a `cargo` error.

A single-layer factoring (source → binary) would hide these failure
boundaries. A three-layer factoring (source, IR, binary) would conflate
the cascade, dispatch, and memory concerns, making it impossible to
specialise one without specialising the others. The nine-layer form is
the coarsest factoring in which each lowering is declarable as a
projection with a clean input/output shape.

### §3.2 The layers are not Rust-specific

L0 through L5 are host-language-neutral. They are expressed in canonical
JSON IR and operate on it structurally. L6 is the first layer that knows
Rust; L7 and L8 are Rust-specific artefacts (source and binary).

This partition is important for two reasons. First, a port to another
target language (Go, WebAssembly) adds layers L6' through L8' in parallel
to L6–L8 without reshaping the specialiser. Second, the cross-language
byte-identity demonstrated in Phase D (§6.4) is only possible because
L0–L5 admit no Rust-specific or Ruby-specific assumptions; the IR the
specialiser consumes is language-neutral by construction.

---

## §4 Projections as Declared Data

A projection is represented as a first-class aggregate:

```ruby
aggregate "Projection", "One L_n → L_(n+1) lowering step" do
  attribute :name,           String
  attribute :from_layer,     String
  attribute :to_layer,       String
  attribute :transform_kind, String  # parse|normalize|graph|lower|emit|compile
  attribute :description,    String
  attribute :impl_module,    String
  attribute :ship_status,    String
end
```

Partial-evaluating the interpreter at any level $L_k$ yields a specialised
program over $L_k, L_{k+1}, \dots, L_8$. The data-level treatment makes
the composition expressible as a query: "for target `validator`, what is
the projection chain L0 → L1 → L6 → L7?"

For `validator.rs`, L2–L5 is irrelevant — validation is purely
declarative and requires no runtime dispatch — so the useful chain is
L0 → L1 → L6 → L7. The layer taxonomy is general so Phase B (additional
module retirements) extends without reshaping the specialiser; a module
with runtime behaviour consumes L2 or L3 alongside L1.

### §4.1 Why declared rather than implicit

The projection chain could be inferred from a module's source: parse it,
observe which IR layers its functions consume, and compute the chain.
This was the first approach. It was abandoned because the inference is
circular during specialisation — the module under retirement is being
replaced, so its source is the output of the process, not its input.

Declaring the chain as data on the capability's bluebook breaks the
cycle. The chain is an input to the specialiser; the module is an
output. The declared form also has a secondary benefit: a reviewer
reading the capability bluebook can see exactly which IR layers the
specialised module will consume, without running the specialiser.

---

## §5 The Specialiser as a Capability

The specialiser is wired as a hexagonal shell adapter rather than
invoked as a build script. `specializer.hecksagon` declares:

```ruby
Hecks.hecksagon "Specializer" do
  adapter :memory
  adapter :fs, root: "."
  adapter :shell,
    name:    :specialize_validator,
    command: "bin/specialize-validator",
    args:    ["--output", "{{output}}"],
    ok_exit: 0
  gate "SpecializeRun", :autophagy do
    allow :Specialize
  end
end
```

The shell adapter is subject to the same security contract as any Hecks
shell adapter: no shell interpretation (`std::process::Command`, not
`sh -c`); env-clear baseline; sealed empty stdin; pgroup SIGKILL on
timeout; per-argument placeholder substitution. The `:autophagy` gate
ensures that `Specialize` cannot be dispatched from a context that does
not carry the capability.

### §5.1 The consequence: codegen is dispatchable

A Hecks CLI session can issue
`Specialize(target: "validator", output: "hecks_life/src/validator.rs")`
from the command bus, not from a shell script. The same authentication,
logging, and event-sourcing infrastructure that wraps every other
command also wraps the specialiser. Every specialisation run emits a
`Specialized` event with the target, the source shape, and the hash of
the produced file.

A running Hecks instance is therefore aware of its own code-generation
pipeline as a participant in the framework, not as an outside actor.
This is novel: classical self-hosting compilers (`rustc`, GHC) invoke
themselves from makefiles; the specialiser and its invocation are not
artifacts the runtime knows about. In Hecks, they are.

### §5.2 Event-sourcing the specialiser

Because `Specialize` is an ordinary command, the event log contains a
complete history of which files were regenerated, from which shapes,
against which source IR, at which time. This is the generator's own
audit trail, maintained as a side effect of running it through the
command bus. Paper 4 of this collection (cascade lockdown) describes
the event-emission assertion pattern that makes such logs trustworthy;
the specialiser's events are subject to the same discipline.

---

## §6 Phases as Shipped

The autophagy arc is organised into five phases, A through E. Each
phase is a distinct architectural step with its own success criterion.

### §6.1 Phase A — First projection, byte-identical

Phase A retires `hecks_life/src/validator.rs`: the hand-written
validator is replaced by a byte-identical generated file. Commit
sequence:

- `1c0a7339` — describe `validator.rs` as a shape-only bluebook at
  `hecks_conception/capabilities/validator_shape/validator_shape.bluebook`
  with rule bodies in a sibling `.fixtures`.
- `5b7660f2` — declare the L1–L6 IR as value-objects in
  `hecks_conception/capabilities/specializer/specializer.bluebook`.
- `a2913cc2` — first-Futamura proof: byte-identical `validator.rs`
  generated via the hecksagon-wired shell adapter. Golden test at
  `hecks_life/tests/specializer_golden_test.rs`.
- `e33c6672` — retire hand-written `validator.rs`; the file carries a
  GENERATED FILE header citing `bin/specialize-validator --output
  hecks_life/src/validator.rs`. Integration tests move to
  `hecks_life/tests/validator_rules_test.rs` to break the circular
  dependency between validator and its own tests.

The generated header reads:

```text
//! GENERATED FILE — do not edit.
//! Source:    hecks_conception/capabilities/validator_shape/
//! Regenerate: bin/specialize-validator --output hecks_life/src/validator.rs
//! Contract:  specializer.hecksagon :specialize_validator shell adapter
//! Tests:     hecks_life/tests/validator_rules_test.rs
```

### §6.2 Phase B — Additional module retirement

Phase B extends retirement, ordered declarative-first so the
partial-evaluation surface grows monotonically:

1. `validator.rs` and `validator_warnings.rs` (Phase A plus the
   warnings module).
2. `fixtures_parser.rs`, `behaviors_parser.rs`, `hecksagon_parser.rs`.
3. `dump.rs` (the canonicaliser — almost declarative).
4. `heki/*.rs` (heki I/O modules).
5. Runtime primitives (command bus, cascade, adapter dispatch).
6. CLI and `main.rs` subcommand dispatch.
7. The parsers themselves (hardest, self-referential).

Status at commit `c4a903f3`: items 1, 2, 3, and the lifecycle and
duplicate-policy validator variants are retired. Items 4 through 7 are
in progress.

### §6.3 Phase C — Second projection, fixed point (restricted form)

Phase C lifts the specialiser into its own bluebook and applies it to
itself, producing $\mathtt{compiler} = \mathtt{mix}(\mathtt{mix}, I)$
in a restricted form: the meta-specialiser regenerates its own
checkers, and the fixed point
$\text{binary}_N \equiv \text{binary}_{N+1}$ holds over two iterations.

The shipped artifact is
`hecks_conception/capabilities/diagnostic_validator_meta_shape/`: a
meta-shape that generalises over diagnostic validators (the family that
includes `validator_shape`, `lifecycle_validator_shape`,
`duplicate_policy_validator_shape`). Specialising the meta-shape
produces the family; specialising the meta-specialiser on itself
produces the same meta-shape byte-identically.

The fixed-point test runs in CI and compares the regenerated
meta-specialiser to the checked-in artifact. A difference is a
regression of deterministic codegen.

### §6.4 Phase D — Cross-language specialiser port

Phase D ports the specialiser from Ruby to Rust. The Ruby specialiser at
`bin/specialize` and `lib/hecks_specializer/` produced the shipped Phase
A artifact. Phase D introduces a Rust equivalent at
`hecks_life/src/specializer/` and asserts byte-identity between the two.

The test passes on first run. This is the empirical claim made in
Paper 5 of this collection (parity as language-neutrality pressure):
because parity between Ruby and Rust parsers had already forced the IR
to be language-neutral, a Rust specialiser consuming the same IR could
produce the same output without additional adaptation.

### §6.5 Phase E — Deletion

Phase E deletes the Ruby specialiser entirely. `bin/specialize`,
`lib/hecks_specializer.rb`, the 16 Ruby specializer modules under
`lib/hecks_specializer/`, and the five Rust meta-specialisers that had
been emitting Ruby files are all removed. Net deletion is approximately
3,000 lines of code.

At commit `c4a903f3` the autophagy tracker reports **100% autophagy
completeness over 2,095 in-scope lines of code**. Every in-scope Rust
module regenerates byte-identically from its shape. The
`hecks-life specialize <target>` subcommand is the sole
code-generation path; the Ruby gem at `lib/hecks/` survives as
host-language binding for Rails integration.

The two-runtime framing that §3 presented as the starting point has, as
of Phase E, collapsed into *one-runtime-plus-one-binding*. Hecks is a
Rust binary with a Ruby authoring surface; the "Ruby framework" framing
is obsolete.

### §6.6 Two bars to distinguish

We distinguish carefully between two properties often conflated in the
self-hosting literature:

- **Bootstrapping.** $\text{binary}_N$ compiles its sources to produce
  $\text{binary}_{N+1}$ that runs correctly — functionally equivalent
  to $\text{binary}_N$. Timestamps, symbol order, and non-determinism
  in code generation may differ.
- **Strict self-hosting.** $\text{binary}_N \equiv \text{binary}_{N+1}$
  byte-identically. Requires deterministic codegen.

`rustc` and GHC (Jones *et al.*) are bootstrapped in the first sense;
they are not byte-identical across self-compilation. Phase A already
demonstrates byte-identical regeneration at the file level (for
`validator.rs`); Phase C demonstrates the same at the meta-specialiser
level; Phase D demonstrates it across a language boundary (Ruby → Rust);
Phase E collapses the first language out entirely. Full-binary strict
self-hosting across every `.rs` module is the open remaining bar.

---

## §7 Related Work

**Futamura projections.** The canonical reference is Futamura (1971),
restated in Jones, Gomard, and Sestoft (1993). The machinery is
classically developed in general-purpose-language settings (Scheme,
SML, a subset of C). The application to a domain compiler's runtime
is, to the author's knowledge, new as of this deposit.

**Self-hosting compilers.** `rustc` and GHC are canonical self-hosting
compilers in the bootstrapping sense. They run themselves on their own
source; they do not guarantee byte-identical output across iterations.
Hecks differs in two respects: (i) it is not a general-purpose-language
compiler but a domain compiler, and (ii) its self-hosting is scoped to
a declared L0–L8 factoring with byte-identity as the correctness
criterion.

**Partial-evaluation systems.** PE Mix (Jones *et al.*), Tempo
(Consel *et al.*), C-Mix, and the family of offline partial evaluators
for ML derive their residual programs statically. Truffle's dynamic
partial evaluator (Würthinger *et al.*) specialises at run time on the
JIT. Hecks's specialiser is offline in the PE sense — it runs at
build time, emits residual Rust, and then exits — but is dispatched
through the framework's command bus rather than by the build system.

**Staged compilation.** MetaOCaml, LMS (Lightweight Modular Staging,
Rompf and Odersky), and Terra stage programs into generators. The
L0–L8 factoring is a staging, in that each layer is a separate
compilation concern with a declared input/output. The distinction from
MetaOCaml/LMS is that the staging is declarative data rather than a
type-level construct.

**Model-driven engineering.** EMF and Xtext share the shape of emitting
runtimes from a metamodel. The distinction is the presence of a
partial evaluator in Hecks — the framework does not only generate
runtimes from models but specialises its own runtime against those
models, iteratively, through a fixed point.

**Interpreter-as-declared-data.** Truffle treats interpreters as
annotated classes from which specialised code is derived at run time.
Hecks's L0–L8 aggregates are the offline counterpart: the runtime's
shape is declared as bluebook aggregates, not as host-language
annotations.

**Related DDD runtimes.** Axon Framework, EventFlow, Akka Persistence,
and Marten/Jasper are DDD-adjacent runtimes. None known to the author
apply partial evaluation to their own runtime or declare their IR
layers as first-class data.

---

## §8 On the Role of the Futamura Framing

The autophagy arc developed in §5–§6 is framed as an instance of
Futamura-style partial evaluation: §2 adopts the three-projection
notation, §6 names the phases after it, and §4 treats the L0–L8
factoring as projections as declared data. This framing is useful and we
believe it is accurate. It is not, however, how the arc was derived.

The design decisions that enabled autophagy — the five-DSL vocabulary,
the antibody enforcement, chapter self-hosting, contract-driven
generation, the binary-compilation step — were each reached from the
internal logic of treating domains as first-class data. If a domain can
declare itself, then the framework that models domains should also be
expressible in the same terms; if a compiler can emit binaries for
target languages, then at some point the compiler should emit its own
binary; if two runtimes must agree on an IR, then the IR must be
language-neutral enough to specialise in either direction. None of these
steps required a partial-evaluation textbook. They followed from DDD
and self-description pressure applied recursively.

Futamura's three projections were recognised afterward, as a naming for
the fixed points the work was already heading toward. The theory
retroactively legitimised the arc — it gave us crisp phase names, an
established vocabulary for the distinctions between a compiler, a
specialiser, and a specialised specialiser, and a formal account of why
what we were building was coherent. But the theory did not make the work
tractable; the shapes, the parity, and the disciplined progression
through L0–L8 did.

This distinction matters for two reasons. First, it means the approach
is reproducible without requiring PL-theory expertise: a project that
drives toward domain-as-data through DDD and self-description intuitions
can arrive at the same structure. Second, it clarifies what Futamura
buys here. It does not buy execution; the specialiser would work without
the name. It buys *recognition* — that the fixed points we were heading
toward are a known termination point of a known construction, and that
the phase structure we used is the one partial-evaluation theory
predicts.

### §8.1 Attributions

Three attributions are owed to work that enabled this arc.

**Evans (2003).** The generative intuition the autophagy arc depends on
— that patterns in a well-modelled domain recur at multiple scales, and
that the model itself is a domain artifact — is drawn from *Domain-
Driven Design*. Evans presents the self-similarity of domain models as
a boon: entities contain value objects, aggregates contain entities,
bounded contexts contain aggregates, and the shared model a team builds
is itself an object that can be reasoned about. The text does not settle
whether Evans anticipated that this observation, followed far enough,
would land on self-hosting and autophagy, but the hint is there to be
read. We followed it; the formal theory that subsequently named our
fixed points is a downstream observation relative to the DDD one.

**Cockburn (2005).** *Hexagonal Architecture* does for the boundary of
a domain what Evans did for its interior. Without a declared port
boundary, a specialiser dispatched as a shell adapter (§5) has no
natural home in the framework; it has to be invoked from outside the
system as a build script, which leaks the codegen pipeline out of the
domain. Cockburn's pattern is what allows the specialiser to be
*inside* the hexagon, wrapped by the same command bus as every other
capability.

**Matsumoto.** Ruby — `instance_eval`, `method_missing`, implicit block
receivers, the tradition that makes a `.bluebook` file *both*
executable Ruby *and* inspectable data — is the substrate on which the
five-DSL vocabulary is expressible as syntax rather than as parsed
strings. The parity story with Rust is possible *because* Ruby's
metaprogramming is expressive enough that a hand-written external
parser can recover the same IR from the same text.

### §8.2 A regret and a counter-direction

A regret is unavoidable given the third attribution. The Phase D and
Phase E programme described here systematically *removes* Ruby from the
framework's code-generation path. The specialisers Phase D is porting to
Rust are the same Ruby modules whose authorability was a gift of
Matsumoto's language design. The elimination is the right choice for
this runtime — Rust is faster, more memory-efficient, and operationally
simpler — but it is not a light one.

A counter-direction exists in principle. Futamura's projections do not
privilege a target language. A specialiser that takes Ruby as its
*host* and produces performant equivalents — a *Ruby-to-fast-Ruby*
compiler in the PE sense — would collapse Ruby's runtime overhead
without touching the language's expressiveness at authoring time.
Mainstream Ruby has had performance work of many shapes (YJIT,
TruffleRuby, typed-optimisation paths) but not, to the author's
knowledge, a domain-aware partial evaluator that starts from the kind
of declared-shape IR Hecks maintains. We flag this explicitly as
future work for any intrepid programmer or agent: Futamura applied to
Ruby itself, with a hand-written L0 shape describing the target IR,
yielding a generated Ruby runtime that is both authorable in Ruby *and*
fast. The techniques in §5–§6 are not specific to Rust; they are about
factoring a runtime through an L0–L8 IR, which any language with a
sufficiently expressive host can reproduce.

---

## §9 Techniques and Novel Claims

1. **Nine-layer factoring (L0–L8) of a DDD runtime into pure-function IR
   lowerings.** `hecks_conception/capabilities/specializer/specializer.bluebook`.
2. **Projections as declared data.** The `Projection` aggregate names
   `from_layer`, `to_layer`, `transform_kind`, and `ship_status`;
   projection chains are queryable from the bluebook rather than
   inferred from source.
3. **Specialiser wired as a hexagonal shell adapter, not as a build
   script.** `hecks_conception/capabilities/specializer/specializer.hecksagon`;
   the codegen pipeline is dispatchable as a domain command.
4. **Capability gate for the specialiser.** `gate "SpecializeRun",
   :autophagy do allow :Specialize end`; a command cannot be dispatched
   from a context that lacks the declared capability.
5. **Event-sourced codegen.** Every specialisation emits a `Specialized`
   event with target, source shape, and output hash. The event log is
   the generator's audit trail.
6. **Byte-identical first-projection retirement of `validator.rs`** with
   a golden test. `hecks_life/tests/specializer_golden_test.rs`;
   GENERATED FILE header citing the regeneration command.
7. **Byte-identical second-projection fixed point (restricted form)** via
   a meta-specialiser regenerating its own checkers.
   `hecks_conception/capabilities/diagnostic_validator_meta_shape/`.
8. **Cross-language specialiser port with byte-identity on first run.**
   Phase D; evidence that L0–L5 is language-neutral by construction
   (see Paper 5 for the methodology argument).
9. **Deletion phase.** The original Ruby specialiser — 3,000 lines of
   code — is removed; the surviving specialiser is the Rust one. The
   Ruby gem persists only as host-language binding, not as
   code-generation path.
10. **100% autophagy completeness reporting.** The
    `autophagy_tracker_shape` aggregate emits `(in-scope LoC, regenerated
    LoC)` on every build; at commit `c4a903f3` the reading is
    2,095 / 2,095.
11. **Bootstrapping vs. strict self-hosting distinction.** Formalised in
    §6.6; byte-identity rather than functional equivalence is the
    correctness criterion for Hecks's self-hosting claim.

---

## §10 Conclusion

Applying Futamura-style partial evaluation to the runtime of a DDD
compiler is tractable if the runtime is factored into nine IR layers
declared as data, the specialiser is wired as a framework capability
rather than invoked as a build script, and byte-identity is the
correctness criterion rather than functional equivalence. Five phases —
first-projection retirement, additional module retirement,
second-projection fixed point, cross-language specialiser port, and
deletion — have shipped over the period covered by this deposit. The
artefacts are reproducible from the public repository at commit
`c4a903f3`. We place the techniques in the public record as prior art.
