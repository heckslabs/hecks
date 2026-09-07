# Behavior is projected, not ported — three tiers, and the host floor

**Status:** Proposed, not implemented. This ADR names the boundary that decides
whether a piece of behavior can be made drift-free between Ruby and Rust, sorts
the existing codebase against it, and commits to four phases of work scoped in
[`docs/behavior-projection-plan.md`](../behavior-projection-plan.md). No code
changes ship with it. Extends
[0009](../implemented/decisions/0009-language-describes-shape-not-interpreter-or-io.md),
[0010](0010-ruby-is-the-reference-implementation.md),
[0011](../implemented/decisions/0011-rust-compiles-types-interprets-dispatch.md)
and [0022](0022-self-host-the-expression-grammar.md); does not supersede any of
them.

## Context

The stated goal is to project both runtimes from one description of behavior so
they can no longer drift. That goal is reachable for a large part of the
dispatch pipeline and unreachable for the rest, and the two have not previously
been separated by anything sharper than intuition. This ADR draws the line, and
records what was measured rather than assumed.

### Two implementations plus a gate is not the same claim as one description

Three distinct arrangements exist in this repo today, and only the third
eliminates drift:

**Tier 1 — checked.** Two implementations, a spec holding them equal:
`spec/operator_conformance_spec.rb`, `spec/vocabulary_conformance_spec.rb`,
`spec/parser_parity_spec.rb`, `spec/rust_conformance_spec.rb`,
`bin/check_engine_agreement`. Drift is detected after the fact, and only where
the gate has a case for it. `bin/check_engine_agreement` exists because two
comparator tables drifted **twice, silently** — `none_in_state` added to one
copy only (every row excluded), and `comparable` disagreeing about a value
object with two numeric members.

**Tier 2 — generated router, hand-written leaves.**
`bin/project_kernel_capabilities` generates an exhaustive `OperatorCategory`
from the live grammar; `rust/src/kernel/expr.rs`'s `dispatch_operator` matches
it with no wildcard arm; `bin/rust_kernel_coverage` fails when an admitted
capability has no file at the conventional path. *Coverage* drift becomes
impossible. *Semantic* drift inside a leaf does not — `.empty?` can still mean
one thing in `expression_operators/sized.rs` and another in Ruby's `Resolver`.

**Tier 3 — one description, generic interpreters.** No hand-port exists, so
there is nothing to drift. Exactly three things are here: refusal wording, the
parser keyword tables, and `given`/`ensures`/`invariant` semantics. A predicate
cannot diverge between runtimes because nobody ports one — it travels as `Expr`
data and each runtime walks it generically.

Tier 3 is the target. Tier 1 is where most of the surface still sits.

### Declaring a subsystem does not move it to Tier 3

This is the trap, and the repo contains a clean demonstration of it.
`lib/hecks/grammar/translation.bluebook` declares schema evolution thoroughly —
a closed ten-member `Kind` set, an `Execution{target, form}` list, and an
admission gate stricter than anything the expression grammar has:

    given("a rule must execute in every target before it is admitted") { executions.size >= 2 }

Nothing reads `executions`. Grep across `lib/` and `bin/` finds no consumer at
all. `Expression::Operator.renderings` is the same shape with the same outcome:
42 rows, **32 `ruby` and 10 `rust`**, carrying illustrative notation (`a || b`,
`haystack.include?(needle)`) that no generator could execute, and reached only
by a passthrough in `lib/hecks/grammar.rb:59`.

Both are admission-time documentation gates wearing Tier 3 clothing. The
conclusion is that **declaring a vocabulary and carrying a behavior are
different acts**: the first closes the coverage question, the second closes the
semantics question, and only the second removes drift.

### The measured asymmetry, and the one real gap

Mutations were expected to be the place where behavior is not yet data. Reading
the actual pipeline shows something narrower and more useful: **a mutation is
already data, in IR, today.** `spec/golden/ir/Bluebook.json` carries records of
the form

    { "op": "set", "sign": "", "source": { "kind": "argument", "name": "name" }, "target": "name" }

`sign` is the `Vocabulary::MutationOp` column, already projected. Ruby already
interprets that record generically:
`lib/hecks/runtime/command_interpreter/mutation_applier.rb` is a 280-line
`case mutation.op` over all nine ops.

Rust does not. `rust/src/kernel/dispatch.rs` takes `apply_mutations` as an
`impl FnOnce(&mut T)` closure — supplied, not interpreted — and that closure is
generated per command by `rust/project/mutations.rb` (834 lines) plus
`rust/codegen/src/mutations.rs` (521 lines).

So the gap is exact and nameable: **the same IR data, interpreted by Ruby and
compiled by Rust.** That is precisely the split
[0011](../implemented/decisions/0011-rust-compiles-types-interprets-dispatch.md)
drew for types versus dispatch; mutations landed on the compile side and were
never moved after predicates were. The eight "ported for real" ADRs — 0040,
0042, 0045, 0046, 0047, 0049, 0050, 0052 — are the running cost of that, one per
shape where somebody eventually noticed Rust disagreeing. Teaching a *generator*
a new op means new source-emission logic; teaching an *interpreter* one means a
match arm.

### The floor is host capability, and it already has an open instance

[0036](0036-postgres-era-cross-runtime-concurrency-gap-investigated-not-yet-closed.md)
is the boundary made concrete. Ruby holds an in-process `Mutex`
(`Runtime::AggregateLock`) across `run_dispatch_order`; `rust/host/src/dispatch.rs`
holds `pg_advisory_xact_lock(hashtext(...))` across its own hydrate-then-append.
In that ADR's own words: *"if the same aggregate is ever dispatched by both a
Ruby process and a Rust process concurrently, there is no protection against a
lost update between them at all."*

No declaration fixes that. It is not a vocabulary disagreement; it is two host
mechanisms that cannot see each other. Schema evolution is therefore the
instructive case in both directions at once: its *rules* are among the
best-declared things in the repo and still drift, while the *storage protocol*
beneath them cannot be projected at any level of declaration.

## Decision

**A piece of behavior belongs in Tier 3 if and only if it passes three tests.**
Expressibility as a `.bluebook` subsystem is not among them, and conflating the
two is what let `Rendering`/`Execution` read as a guarantee.

1. **Do both runtimes execute it?** If not, declaring it buys inventory,
   `bin/evolve` governance and projected docs — all worth having, none of them
   this ADR's subject.
2. **Does the per-instance behavior reduce to a closed set of node kinds?**
   Arbitrary protocol does not.
3. **Do those nodes bottom out in pure computation, or in host capability?**
   `save`, `hydrate`, `emit` and `resolve_references` bottom out in a
   repository. They are floor.

Applying the tests to `AggregateDispatchOrder`'s own sixteen steps:

| | steps |
|---|---|
| **Already Tier 3** | `enforce_givens`, `enforce_ensures`, `enforce_invariants` |
| **Can reach Tier 3** | `refuse_unknown_arguments`, `refuse_absent_arguments`, `normalize_args`, `refuse_role_mismatch`, `admissible_transition`, `assign_creation_attributes`, `apply_mutations`, `advance_lifecycle` |
| **Permanent floor** | `resolve_references`, `hydrate`, `save`, `emit`, and the routing half of `delegate_to_entity` |

**Four phases follow, scoped in
[`docs/behavior-projection-plan.md`](../behavior-projection-plan.md).**

- **Phase 1 — Rust interprets mutations instead of compiling them.** A generic
  applier over the mutation records already in IR, one
  `kernel/mutation_ops/<op>.rs` per admitted op, routed by a generated
  exhaustive enum and held by the same missing-file rule
  `bin/rust_kernel_coverage` already applies to expression operators. Ruby's
  `MutationApplier` is the reference implementation, per
  [0010](0010-ruby-is-the-reference-implementation.md).
- **Phase 2 — the dispatch sequence into IR.** Ruby already reads it
  (`CommandInterpreter::DISPATCH_ORDER = Hecks::Vocabulary.symbols("AggregateDispatchOrder")`,
  "the sequence is data-driven"); `kernel/dispatch.rs` and `host/dispatch.rs`
  hardcode their own. This single-sources order and presence, not step
  semantics.
- **Phase 3 — resolve `Rendering`/`Execution`.** Either `form` names the
  implementing capability file, making it checkable by the same rule as
  Phase 1, or the "executes in every target" language is demoted to
  documentation. The present state — a hard `>= 2` gate over content nothing
  reads — is the worst of both.
- **Phase 4 — declare and gate the query/read-model vocabularies.** Not a port:
  `kernel/named_query.rs` and `kernel/read_model.rs` already interpret static
  tables generically. What is missing is that read-model aggregations
  (`group_by`/`count`/`median`) and null-ordering modes
  (`native`/`first`/`last`) are closed sets in behavior with no declaration and
  no gate, which is what 0050, 0052 and part of 0040 cost. Gated by conformance
  spec rather than generated enum, following
  `spec/query_comparator_conformance_spec.rb`'s own reasoning: once a real
  dispatch site exists, the file is hand-maintained code and there is nothing
  for a generator to regenerate.

**For the floor, the instrument is contract narrowing, not projection.** `.port`
already declares `signal: reply|effect` and a `PortAnswer` list naming the
methods an adapter must answer. What eventually closes
[0036](0036-postgres-era-cross-runtime-concurrency-gap-investigated-not-yet-closed.md)
is not a bluebook of concurrency; it is one declared locking port both runtimes
bind, so the two mechanisms stop being invisible to each other.

## Consequences

- Predicates, mutations, lifecycle transitions, normalisation, refusal wording,
  and the step sequence become drift-free by construction. Persistence, HTTP,
  auth, journaling and era concurrency remain two implementations under a
  narrowed port contract, checked by the differential harness.
- The eight-ADR-per-op pattern ends. Adding a tenth mutation op becomes a
  vocabulary row, one Ruby arm and one Rust file, with a red build until all
  three exist — no ADR, because there is nothing to discover.
- Line count is not the payoff and should not be used to justify the work. Most
  of `rust/project/mutations.rb` is **type bridging**, not op semantics —
  `list_attr_creation_optional?`, `optional_value_rhs`, `identity_components`,
  value-object unwrapping, `Option` wrapping — and survives Phase 1 intact,
  because a statically typed target still has to resolve an IR `source` to a
  Rust type. What collapses is the per-op emission.
- Tier 2 remains a real intermediate state, not a failure. A generated
  exhaustive router with a coverage gate is what makes a leaf's absence
  impossible; it simply does not make a leaf's *contents* agree.

## Open, deliberately

- **The "identically wrong" class is untouched.** `docs/implemented/rust-experiment.md`
  names it directly: the two-runtime discipline caught "places both runtimes
  agreed *and were identically wrong*... agreement is not correctness."
  Single-sourcing removes the disagreement class entirely and does nothing for
  this one, which stays the job of `bin/model_check` and the fuzzer's declared
  properties ([0024](../implemented/decisions/0024-fuzzer-properties-are-claimed-against-the-language-grammar.md)).
- ~~**Read-model and query semantics are a plausible fourth candidate,** not
  scoped here.~~ **UPDATE (same session): investigated and scoped as Phase 4 —
  and the premise above was wrong.** Rust does *not* compile queries or read
  models the way it compiles mutations: `kernel/named_query.rs` and
  `kernel/read_model.rs` are each "the ONE hand-written interpreter" walking a
  static `QueryDef`/`ReadModelDef` table, "never bespoke per-query Rust control
  flow" (their own headers). The Phase 1 move is already done here. What is
  missing is narrower — two undeclared vocabularies and the gates over them —
  so Phase 4 is an enforcement phase, not a port. See the plan.
- **Which of the eight "can reach Tier 3" steps are worth the move** beyond
  `apply_mutations` is unproven. The other seven are small and structural; none
  has produced a porting ADR, which is weak evidence that they are not currently
  drifting.

## Rejected alternatives

- **Project the interpreter itself.** The strong version — derive both runtimes'
  dispatch loops from one description.
  [0011](../implemented/decisions/0011-rust-compiles-types-interprets-dispatch.md)
  tried the per-instance form of this and it did not converge ("needed a new
  hand-written case in the generator... the same failure mode [as] the retired
  Rust runtime"), and [0022](0022-self-host-the-expression-grammar.md) records a
  predecessor project proving a genuine Futamura second-projection fixed point
  for one routing table and then retiring the machinery as not worth its
  legibility cost. The rule both converge on holds here: structure tolerates
  derivation, open-ended semantics does not.
- **Make `Rendering.form` executable source per target.** Storing runnable Ruby
  and Rust in the ledger would put two implementations back in one file and
  make the grammar chapter the place where target-specific code lives —
  inverting [0009](../implemented/decisions/0009-language-describes-shape-not-interpreter-or-io.md)
  rather than extending it. Phase 3 names the capability file instead, which is
  checkable without the ledger carrying code.
- **Declare the era/locking protocol as a bluebook.** Fails test 3. The
  disagreement in [0036](0036-postgres-era-cross-runtime-concurrency-gap-investigated-not-yet-closed.md)
  is between an in-process mutex and a database advisory lock; a declaration of
  it would describe the divergence without removing it.
- **Rely on the differential harness alone.** It is necessary and already
  exists (`bin/rust_conformance`, `bin/check_engine_agreement`,
  `spec/parser_parity_spec.rb`), but it detects rather than prevents, and
  `check_engine_agreement`'s own header records two drifts that reached shipped
  code before a gate was written for them.
