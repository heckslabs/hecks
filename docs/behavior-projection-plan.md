# Behavior projection: implementation plan, phases 1–3

**Status: proposed, nothing implemented.** The decision this executes is
[ADR 0053](decisions/0053-behavior-is-projected-not-ported.md) — read it first;
it carries the three-tier framing, the three candidacy tests, and the reasoning
for why the floor is floor. This document is the ordering, the file-level scope,
and the gates.

Every count below was measured against this checkout, not estimated. The
commands that produced them are named beside each figure so a later session can
re-derive rather than trust.

## Governing principles (settled — do not relitigate mid-phase)

1. **Ruby is the reference implementation**
   ([0010](decisions/0010-ruby-is-the-reference-implementation.md)). Where a
   phase makes Rust interpret something Ruby already interprets, Ruby's existing
   walker is the specification. Behavior changes to Ruby are out of scope for
   every phase here; if a phase surfaces a Ruby bug, it gets its own ADR (the
   [0047](decisions/0047-remove-mutation-op-is-a-real-ruby-bug-not-a-porting-gap.md)
   precedent), not a silent fix inside the refactor.
2. **A capability's absence must be structural, never a comment.** New capability
   families follow the established rule: one file per member at a conventional
   path, an exhaustive generated enum with no wildcard arm, and
   `bin/rust_kernel_coverage`'s missing-file check. Its own header states why no
   marker comment is acceptable — "a missing FILE at the conventional path
   cannot lie either way."
3. **No phase widens the language.** No new keyword, no new `syntax.bluebook`
   row, no `bin/evolve` run. Every phase reads vocabulary that is already
   declared and already admitted.
4. **Line count is not the goal.** The goal is that a future divergence becomes
   a red build instead of an ADR. A phase that deletes nothing and closes a
   drift class has succeeded.

---

## Phase 1 — Rust interprets mutations instead of compiling them

**The gap.** A mutation is already data in IR:

    { "op": "set", "sign": "", "source": { "kind": "argument", "name": "name" }, "target": "name" }

Ruby interprets that record generically —
`lib/hecks/runtime/command_interpreter/mutation_applier.rb`, 280 lines, one
`case mutation.op` over all nine ops. Rust does not: `rust/src/kernel/dispatch.rs`
receives `apply_mutations` as an `impl FnOnce(&mut T) -> Result<(), Refusal>`
closure (`:137`, `:358`, `:448`) that is *generated per command* by
`rust/project/mutations.rb` (834 lines) and `rust/codegen/src/mutations.rs`
(521 lines).

Same data, interpreted on one side and compiled on the other. That is the whole
of the drift surface, and it is the direct cause of the per-op porting ADRs
(0040, 0042, 0045, 0046, 0047, 0049, 0050, 0052).

**Ground truth.** `Vocabulary::MutationOp`
(`lib/hecks/language/bluebook/vocabulary.bluebook:106`) — nine members, each with
its `sign` column already projected into IR:

| op | sign | notes |
|---|---|---|
| `set` | — | |
| `append` | — | multi-binding wire shape (`fields:`) |
| `increment` | `1` | `current + sign * amount` |
| `decrement` | `-1` | same primitive, opposite sign |
| `multiply` | — | `current * amount` |
| `clamp` | — | `current.clamp(min, max)` |
| `remove` | — | list removal, matched by value |
| `delegate` | — | **deferred, see scope** |
| `corrects` | — | **deferred, see scope** |

**Corpus surface** (`grep -rho "sets :[a-z_]*, *\(to\|append\|…\):" examples/
lib/hecks/framework/bluebook/`): 43 declared sites across four ops — `to:` 20,
`append:` 10, `increment:` 8, `decrement:` 5. The other five ops are live in
both runtimes but have little or no corpus motivation, which
[0041](decisions/0041-phase-10-remaining-backlog-scoped-not-shipped.md) already
recorded. This phase is a refactor of existing, shipped behavior — **not a
feature port** — so every op must keep working whether or not the corpus
exercises it.

### Scope

**In:** the seven value ops — `set`, `append`, `increment`, `decrement`,
`multiply`, `clamp`, `remove`.

**Deferred, with reasons:**

- `corrects` — its admissibility check lives in
  `CommandRules::Admissibility#enforce_correction_target`, not in the mutation
  applier, and its Rust side rests on the snapshot-format extension
  [0049](decisions/0049-corrects-mutation-op-ported-for-real.md) shipped under
  explicit authorization after
  [0048](decisions/0048-corrects-kernel-gap-precisely-scoped-two-real-design-options.md)
  found the blast radius universal. Moving it in the same pass as six ordinary
  value ops would put that decision back in play for no gain.
- `delegate` — a synchronous handoff into a nested entity command. It is routing
  wearing a mutation's wire shape, and belongs with Phase 2's dispatch work if
  it moves at all.

### Deliverables

1. `rust/src/kernel/mutation_ops/<op>.rs`, one per op in scope — the
   interpretation for that op and nothing else, matching the existing
   `expression_operators/<category>.rs` convention exactly.
2. `rust/src/kernel/mutation_ops/mod.rs` — generated by extending
   `bin/project_kernel_capabilities` with a third ground truth alongside
   `Coercion::SHAPES` and `Grammar.admitted_operators`:
   `Hecks::Vocabulary.rows("MutationOp")`, which answers the rows whole
   (`name` **and** `sign`) where `fetch` would answer names only. Exhaustive
   enum, no wildcard arm, same rule and same reasoning as `OperatorCategory`.
3. `kernel::mutations::apply()` — one generic function over the IR mutation
   record, ported from `MutationApplier#apply`. `dispatch.rs`'s three closure
   parameters become calls into it.
4. `bin/rust_kernel_coverage` extended by one row — its `check(category_dir,
   names, source)` helper (`:66`) is already generic, so this is
   `check("mutation_ops", Hecks::Vocabulary.fetch("MutationOp"), …)` beside the
   two existing calls (`:73`, `:75`).
5. `rust/project/mutations.rb` and `rust/codegen/src/mutations.rs` reduced to
   **type bridging only**.

### What does not collapse — read this before estimating

Most of `mutations.rb` is not op semantics. `list_attr_creation_optional?`
(`:21`), `optional_value_rhs` (`:533`), `identity_components` (`:395`),
`append_field_rhs` (`:476`), `state_field_rhs` (`:524`) and the value-object
unwrapping around them exist because Rust is statically typed and an IR
`source` — an argument, a literal, a state field — must still resolve to a
concrete Rust type and `Option` depth. All of that survives. What collapses is
`emit_mutation_line`/`emit_mutation_line_body` (`:594`, `:608`) and the per-op
emission beneath them.

Anyone reporting this phase as "deleted 1,355 lines" has mis-scoped it.

### Gates

- `bin/rust_kernel_coverage` — must report every `MutationOp` member present.
- `cargo build` — the exhaustive match is the real gate; it must fail on a
  hand-added enum variant with no arm. **Verify this by deliberately breaking
  it once**, the way `expr.rs`'s own header describes, before trusting it.
- `bin/rust_conformance` + `spec/rust_conformance_spec.rb` — unchanged pass rate.
- `codegen_parity` and `spec/parser_parity_spec.rb` — unchanged.
- `bundle exec rspec` full suite, `bin/model_check` 0 errors, rubocop clean.

### Proof of done

Adding a tenth mutation op requires: one `member` row in
`vocabulary.bluebook`, one arm in Ruby's `MutationApplier`, one
`kernel/mutation_ops/<op>.rs`. The build is red until all three exist, and no
ADR is written, because nothing was discovered.

---

## Phase 2 — the dispatch sequence into IR

**The gap.** Ruby reads its own pipeline order from the language:

    DISPATCH_ORDER = Hecks::Vocabulary.symbols("AggregateDispatchOrder")

(`lib/hecks/runtime/command_interpreter.rb:33`, whose own comment records that
"the sequence is data-driven"), and dispatches `step_<name>` methods by that
list. `rust/src/kernel/dispatch.rs` (517 lines) and `rust/host/src/dispatch.rs`
(1,310) each hardcode an order of their own.

**Motivating bug, already shipped and fixed once.** `EntityDispatchOrder`'s own
declaration comment records bug H1 (`docs/audits/2026-08-10-main-bug-audit.md`):
an entity command ran *neither* argument gate, behind a comment claiming it
"inherits its aggregate's own gate." Order-and-presence drift is the class this
phase closes, and it has already cost once.

### Scope

**In:** emitting the declared step lists into `ir.json`, and making both Rust
dispatchers iterate them.

**Out:** the step *bodies*. This phase single-sources **order and presence**, not
semantics — `hydrate` and `save` stay two hand-written implementations, per
[ADR 0053](decisions/0053-behavior-is-projected-not-ported.md)'s floor.

### Deliverables

1. `AggregateDispatchOrder` and `EntityDispatchOrder` emitted into `ir.json`
   alongside the existing language-level projections.
2. `kernel/dispatch.rs` and `host/dispatch.rs` iterating the emitted list rather
   than an inlined sequence, with a hard failure — not a skip — on a step name
   no arm answers.
3. An order-conformance check: all three implementations answer the same
   sequence for the same construct.

### Why this is testable rather than cosmetic

Refusal *order* is observable behavior, and the corpus already pins it:
`spec/corpus/rust_conformance/refusal_order_invariant_before_reference.json`.
A reordering that changes which refusal fires first is a real, catchable
difference, which is what makes this phase worth doing rather than tidy.

### Gates

Existing `rust_conformance` corpus, plus the new order-conformance check.
No behavior change is expected in any runtime; a diff in the conformance corpus
means the phase found a real pre-existing divergence and that divergence gets
written down before it is fixed.

---

## Phase 3 — resolve `Rendering` and `Execution`

**The problem.** Two `{target, form}` lists present themselves as cross-runtime
guarantees and are not:

- `Expression::Operator.renderings` — 42 rows, **32 `ruby`, 10 `rust`**, forms
  carrying illustrative notation (`a || b`,
  `haystack.include?(needle)`). Reached only by a passthrough at
  `lib/hecks/grammar.rb:59`.
- `Translation::Rule.executions` — gated at admission by
  `given("a rule must execute in every target before it is admitted") { executions.size >= 2 }`,
  and read by **nothing at all** (`grep -rn "executions" lib/ bin/`).

The `>= 2` gate is the sharper of the two and guards content no consumer
examines. That is worse than having no gate, because it reads as a guarantee in
review.

### The decision this phase must make

**Option A — `form` names the implementing capability file.** A rendering
becomes checkable by the same missing-file rule `bin/rust_kernel_coverage`
already applies: the ledger says which file implements this operator in this
target, and the file's absence is the failure. Files already exist at the
conventional paths for the expression operators, so this is largely a matter of
rewriting 42 ledger rows and adding one check.

**Option B — demote to documentation.** Keep the forms as illustration, drop
"executes in every target" from the `given`, and stop counting either list as a
drift control.

**Recommendation: A for `Expression::Operator`, and A as the entry point for
translation.** Making `executions` real is the same move as Phase 1, one layer
out: the structural translation kinds are path-to-path transforms —
`move :price_cents, to: "pizza.price_cents"`
(`examples/pizzas/bluebook/translations/2-77625c.bluebook`) — and are
expression-shaped in exactly the way `compute` and `backfill` are not.

### Scope

**In:** `rename`, `move`, `retype`, `rekey`, `drop` — the structural half of the
ten-member `Kind` set.

**Out:** `compute` and `backfill`, which bottom out in host reads and fail test
3; `unresolved` and `retired`, which are declarations rather than transforms;
and the entire era/storage protocol, which is floor —
[0036](decisions/0036-postgres-era-cross-runtime-concurrency-gap-investigated-not-yet-closed.md)
is that floor's open instance and is not addressed by any phase here.

### Gates

`spec/operator_conformance_spec.rb` and
`spec/translation_vocabulary_conformance_spec.rb`, extended to hold the ledger's
named files to the ones that exist.

---

## The floor, stated once so no phase quietly grows into it

`resolve_references`, `hydrate`, `save`, `emit`, the whole of `rust/host`'s
web (2,405), mint (1,449), journal (1,093) and auth (899) layers, every driven
adapter, and the era concurrency protocol stay two implementations. The
instrument there is **contract narrowing, not projection**: `.port` already
declares `signal: reply|effect` and a `PortAnswer` list naming the methods an
adapter must answer, and what eventually closes
[0036](decisions/0036-postgres-era-cross-runtime-concurrency-gap-investigated-not-yet-closed.md)
is one declared locking port both runtimes bind — not a bluebook of concurrency.

Two things remain outside every phase and outside the floor framing alike:

- **The "identically wrong" class.** `docs/implemented/rust-experiment.md`:
  "places both runtimes agreed *and were identically wrong*... agreement is not
  correctness." Single-sourcing removes disagreement and does nothing for this.
  It stays the job of `bin/model_check` and the fuzzer's declared properties.
- **Query and read-model semantics** — `kernel/query_comparators.rs` (444) and
  `kernel/read_model.rs` (873) against a Ruby side already unified behind
  `QuerySpecification::Common::Comparison`/`NullPolicy`. A plausible fourth
  phase; not investigated, deliberately not scoped here.

## Suggested order

Phase 1 first, alone, and merged before anything else starts: it is the only
phase with a measured, recurring cost behind it, and it establishes the
`mutation_ops/` convention the other two lean on. Phase 3's Option A/B decision
can be made any time and is cheap; Phase 2 is the smallest and can follow either.
