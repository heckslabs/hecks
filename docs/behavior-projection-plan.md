# Behavior projection: implementation plan — two tracks

**Status: proposed, nothing implemented.** The decision this executes is
[ADR 0053](decisions/0053-behavior-is-projected-not-ported.md) — read it first;
it carries the three-tier framing, the three candidacy tests, and the reasoning
for why the floor is floor. This document is the ordering, the file-level scope,
and the gates.

**Two tracks, two different goals, deliberately not merged.**

- **Track A (Phases 1–4) — drift.** Make Ruby/Rust divergence structurally
  impossible where it can be. Justified by the nine incidents in the 0040–0052
  ADR run.
- **Track B (B1, B2) — derivation.** Reduce what has to be generated per
  instance at all. Justified by measuring the generated output, which no ADR
  describes because none of it ever drifted.

The tracks overlap (B1 removes a per-instance treatment of something already
carried as data) but they answer different questions, and a phase that serves
one is not automatically worth doing for the other. Say which argument you are
making when you argue for a phase.

Every count below was measured against this checkout, not estimated. The
commands that produced them are named beside each figure so a later session can
re-derive rather than trust.

## What the generated output actually contains

Read this before prioritising anything. Classifying all 47,050 generated lines
under `rust/src/generated/` by enclosing function:

| function | lines | share |
|---|---|---|
| `from_json` | 9,424 | 20% |
| `to_json` | 5,344 | 11% |
| `field` | 5,030 | 11% |
| `dispatch_by_name` | 4,920 | 10% |
| `as_scalar` | 3,094 | 7% |
| `items` | 2,970 | 6% |
| `check_invariants` | 2,890 | 6% |
| `command_attributes_for_verb` | 1,251 | 3% |
| `extract_id` / `from_seed` / `instances` / `set_projected_field` / `find_fielded` | ~2,650 | 6% |

**JSON codec plus field reflection — `from_json`, `to_json`, `field`,
`as_scalar`, `items`, `find_fielded` — is 26,256 lines, 56% of everything
generated.** None of it is domain behavior; every varying part derives from a
type's field list, which `ir.json` already carries.

**The methodological warning this table exists to carry.** The first draft of
this plan was built entirely from the ADR trail and put mutations at the centre.
Mutations live inside `dispatch_by_name`'s 4,920 lines — roughly a fifth of the
codec layer. They dominated the plan because they produced eight ADRs, and they
produced eight ADRs because they *drifted*. The codec never drifted, so nothing
was ever written about it, so it was invisible. **An ADR log is a record of what
hurt, not a map of what exists.** Any future prioritisation pass should measure
the artifact before reading the decision record.

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

# Track A — drift

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
- `delegate` — **still deferred, but for a corrected reason.** This item
  originally read "routing wearing a mutation's wire shape, belongs with Phase
  2." That was a guess; `step_delegate_to_entity`
  (`command_interpreter.rb:201-249`) has since been read. It is not routing —
  it is an in-aggregate handoff to a nested entity command, driven entirely by
  declared data (the `target` string, the `with:` map, the entity's own IR),
  and Rust generates it per command (`rust/project/commands.rb:585-591`) exactly
  as it does mutations. So it *is* a Phase-1-shaped asymmetry. It is deferred
  because it does not fit the **leaf** convention: `delegate` applies no value
  to a field, it runs a nested sub-pipeline (locate element, givens, transition,
  mutations, lifecycle, ensures, emit), which is why `mutation_applier.rb`'s own
  `:delegate` arm is a deliberate `nil`. Give it its own slice after Phase 1
  establishes the convention, and note that `delegate_skip_reason` means Rust
  already declines to generate some delegations — an admitted-subset boundary of
  the same kind queries and read models have.

  **Flagged while reading, unverified, not this plan's business to fix.**
  `step_delegate_to_entity` hand-inlines the entity dispatch sequence rather
  than going through `EntityInterpreter`, and the sequence it runs is missing
  the first five steps `EntityDispatchOrder` declares —
  `refuse_unknown_arguments`, `refuse_absent_arguments`, `normalize_args`,
  `refuse_role_mismatch`, `resolve_references`. The parent command ran those
  against **its own** attributes, and `with:` then remaps values onto the
  target's attributes, so a value normalised against the parent's declared type
  can reach a target attribute of a different type without being normalised
  against it. That is the shape of bug H1
  (`docs/audits/2026-08-10-main-bug-audit.md`), one level over. It may be
  intentional and it may be covered; nobody has written down which. Worth its
  own investigation before Phase 2 touches dispatch ordering.

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

## Phase 4 — declare and gate the query/read-model vocabularies

**This phase is not shaped like Phase 1, and the first draft of this plan said
otherwise.** The expectation was that queries and read models would turn out to
be compiled per instance in Rust the way mutations are. They are not.
`rust/src/kernel/named_query.rs` and `rust/src/kernel/read_model.rs` are each
"the ONE hand-written interpreter every generated domain's own
`QUERIES`/`READ_MODELS` table is walked through — **never bespoke per-query
Rust control flow**" (their own headers), fed by static `QueryDef`/`ReadModelDef`
rows. Phase 1's move is already done here.

So Phase 4 ports nothing and deletes nothing. It closes the two places where a
closed set exists in behavior but not in the language, and therefore has no gate.

### Already done — do not re-propose

- **`QueryComparator` is gated.** `spec/query_comparator_conformance_spec.rb`
  reads `rust/src/kernel/query_comparators.rs` directly and holds both its `ALL`
  roster and its `parse` wire names to `Vocabulary::QueryComparator`, both
  directions. It exists precisely because that pair drifted —
  `Vocabulary::QueryComparator` grew a ninth name (`none_in_state`) that Rust's
  enum "never caught up to, for however long that drift was already live before
  this spec." Note the file's own reasoning for why a generator cannot replace
  the spec here: once a real dispatch site exists, `query_comparators.rs` is
  hand-maintained code, not a generated roster. **This is the counter-example to
  Phase 1's "generate the enum" pattern and the reason Phase 4 uses specs
  instead.**
- **Attribute shapes and expression-operator categories are gated** by
  `spec/kernel_capabilities_conformance_spec.rb` plus `bin/rust_kernel_coverage`.

### 4a — declare `ReadModelAggregation`

**The gap.** `group_by`, `count` and `median` are three ad-hoc fields on
`IR::ReadModel` (`@group_by`, `@count`, `@median_field` —
`lib/hecks/bluebook/read_model.rb:29`), three ad-hoc predicates in the
interpreter (`model.group_by.any?`, `model.count?`, `model.median_field` —
`read_model_interpreter.rb:67`), a mutual-exclusion rule ("at most one of") that
lives only in `read_model_builder.rb`'s comments and `seal_group_by`, and
matching hand-written arms in `kernel/read_model.rs`. **There is no closed set
anywhere** — `grep -n "Aggregation" lib/hecks/language/bluebook/*.bluebook`
returns nothing.

That absence is what [0050](decisions/0050-group-by-read-model-support-ported-for-real.md)
and [0052](decisions/0052-count-median-read-model-aggregation-ported-for-real.md)
cost: two ADRs for two aggregations, each discovered rather than gated.

**Deliverables.**

1. `value_object "ReadModelAggregation"` in
   `lib/hecks/language/bluebook/vocabulary.bluebook`, members `group_by`,
   `count`, `median`, each carrying whether it takes a field — the same
   `name`/`sign` two-column shape `MutationOp` already uses. Mutual exclusion
   stays a builder rule; the vocabulary names the set, not the arity law.
2. A conformance spec holding the builder, `ReadModelInterpreter` and
   `kernel/read_model.rs` to that set, **modelled on
   `spec/query_comparator_conformance_spec.rb`, not on the generated-enum
   pattern** — `read_model.rs` is hand-maintained interpretation with a real
   dispatch site, exactly the case that spec's header says a generator cannot
   serve.
3. `spec/vocabulary_conformance_spec.rb` extended with the new term, the same
   way `AggregateDispatchOrder` and `QueryComparator` already appear there.

**Proof of done.** A fourth aggregation is a vocabulary row plus arms on both
sides, with a red spec until all three exist — not an ADR.

### 4b — declare `NullPolicyMode`

**The gap.** Three modes — `native`, `first`, `last` — live as bare `case`
strings in `lib/hecks/query_specification/common/null_policy.rb` (`:27`, `:48`),
with `native` as the default (`null_semantics.rb:7`), mirrored by
`kernel/query_ordering.rs`. No vocabulary row, no gate.
[0040](decisions/0040-declared-query-offset-ported-for-real.md) shipped
`nulls :first`/`:last` across both runtimes; nothing prevents a fourth mode from
landing on one side only.

**Deliverable.** A three-member `NullPolicyMode` term in `vocabulary.bluebook`
and its row in the conformance spec. Small enough to ride along with 4a in one
pass; listed separately so it is not silently dropped if 4a slips.

### 4c — make the admitted subset declared, not commented

**The gap, and the honest uncertainty.** `rust/project/queries.rb`'s
`query_skip_reason` and `rust/project/read_models.rb`'s `read_model_skip_reason`
encode which declared shapes get a generated row. Everything outside gets **no
row at all** and is refused cleanly by `kernel/cli.rs` — "never silently wrong,"
and that is genuinely true today. The risk is not wrongness but silent *scope
shrink*: a capability could leave the admitted subset, or a new Ruby capability
could land outside it, with nothing failing.

**Deliverable, if it earns its place.** A declared list of which language
capabilities the Rust subset admits, and a spec asserting that every capability
the language declares is either in the subset or explicitly named as out.

**This item is speculative and should be decided, not assumed.** The skip
reasons are prose today and prose is often the honest form for "we haven't
ported this yet." Do 4a and 4b first and revisit.

### Out of scope — feature gaps, not drift

Reference-hopping `where` clauses in aggregate queries, `cursor`, `consistency`,
`freshness`, `authorize`/TenantScope beyond what
[0040](decisions/0040-declared-query-offset-ported-for-real.md) shipped,
`inspection` and `index_hints` are real `Ports::Query::InMemory` capabilities
with no Rust port. That is a **feature gap**, not divergence: both runtimes
agree, one simply refuses. Closing it is ordinary porting work and does not
belong in a plan about drift.

### Incidents this phase closes

| ADR | capability | closed by |
|---|---|---|
| [0050](decisions/0050-group-by-read-model-support-ported-for-real.md) | `group_by` | 4a |
| [0052](decisions/0052-count-median-read-model-aggregation-ported-for-real.md) | `count`/`median` | 4a |
| [0040](decisions/0040-declared-query-offset-ported-for-real.md) | `nulls :first`/`:last` | 4b (partial — that ADR bundled four capabilities) |

Two full incidents and part of a third, against Phase 1's four. Phase 4 is
cheaper than Phase 1 and closes less; both are worth doing, and Phase 1 first.

# Track B — derivation

Neither item here closes a drift incident. Both are justified by the
measurement table at the top of this document, and the argument for them is
volume and derivation, not divergence. Keep the two arguments apart.

## B1 — invariant checking becomes a table

**The gap.** `rust/project/types.rb:22`'s `emit_check_invariants` generates a
`check_invariants` function per value object — 2,890 lines across the corpus,
six of them in `banking/account.rs` alone. The per-invariant body is
structurally identical every time:

```rust
let ctx = EvalContext { args: &NoFields, instance: self };
if !interpret(&Expr::Compare { … }, &ctx)?.truthy() {
    // render RefusalSite::InvariantViolationValueObjectInvariant
    //   with ("name", …), ("description", …), ("offered", …)
}
```

Everything that varies is already data: the `Expr` is **already emitted as a
literal** (so the hard part is done), and `name`/`description` are in `ir.json`.
The refusal text already routes through the single-sourced `RefusalSite::render`
table. Meanwhile `QUERIES`, `READ_MODELS`, `POLICIES` and `PROCESS_MANAGERS` are
all already static tables walked by one kernel interpreter. Invariants are the
one construct of that family that is not, and reading the code there is no
reason for it beyond nobody having got to it.

**Deliverable.** A static per-type `INVARIANTS` table of `{expr, name,
description}` rows, plus one `kernel::invariants::check()` that walks it —
modelled on `kernel/named_query.rs`'s relationship to the generated `QUERIES`
table.

**The coupling to B2, which the first sketch of this item missed.**
`emit_check_invariants` does *two* things. The predicate half is clean and
standalone. But `types.rb:69` also emits recursion into composed value-object
fields (`self.<field>.check_invariants()?`), and driving that generically needs
the same field enumeration B2 is about. **Ship B1 with the recursion still
generated** — it is a small fraction of the 2,890 lines — and let B2 absorb it
later. B1 is standalone only under that split.

**Scope.** Value objects only. Aggregate and entity invariants have no
generated `check_invariants` (consistent with `value_object.rb:42` being the
only site that emits `ast:` into IR) and are out of scope here.

**Gates.** `bin/rust_conformance` + `spec/rust_conformance_spec.rb` unchanged;
the refusal-wording corpus fixtures under `spec/corpus/rust_conformance/` pin
the exact `InvariantViolation` text, so a wording regression fails loudly.

## B2 — complete the field reflection, then decide about the codec

**The measurement.** `to_json` (5,344) and `from_json` (9,424) are 14,768 lines,
31% of all generated code, and every varying part is a field list. Sampled
bodies are entirely mechanical: `Money::from_json` is an `unknown_keys` check
against `["cents","currency"]` plus a typed read per field;
`AccountKind::from_json` is a match over closed-set members `ir.json` already
carries. Add `field`/`as_scalar`/`items`/`find_fielded` (11,488) and the
structural-reflection layer is 26,256 lines.

**The real blocker, stated up front.** `Fielded`
(`rust/src/kernel/expr.rs:95`) is **read-by-name only** —
`fn field(&self, name: &str) -> Option<Field<'_>>`. There is no field
enumeration and no constructor path, so it cannot drive `to_json` (needs to
iterate) or `from_json` (needs to build). This is not "call serde"; it is
"make reflection complete enough to drive both directions," and the per-type
`Fielded` impl survives either way. **14,768 lines become smaller, not zero.**

**Why serde is not the shortcut.** The kernel crate is deliberately std-only
with zero Cargo dependencies, which is why a codec is generated at all. That
policy is currently costing on the order of 26,000 lines of generated code.
Re-examining it is a legitimate decision in its own right and should be taken
on its own terms — not smuggled in as an implementation detail of this phase.

**This item is a spike, not a commitment.** Do one aggregate end to end before
anyone plans the rest. The 56% is measured; the feasibility is not. Specifically
unverified: whether a generic codec can express entity elements, nested
optional/list combinations, and projected fields without per-type escape
hatches. If the spike needs more than one escape hatch, that is the answer, and
the finding is worth writing down either way.

## The floor, stated once so no phase quietly grows into it

**Corrected after reading the code — the floor is the adapters, not the steps.**
An earlier version of this section listed `resolve_references`, `hydrate`,
`save` and `emit` as floor. All four were then read directly and none of them
is; see ADR 0053's own UPDATE for the evidence. `resolve_references` in
particular is *already projected in both runtimes* — a static `REFERENCE_TABLE`
(`rust/project/reference_specs.rb`, 44 lines) walked by generic functions in
`kernel/reference_lookup.rs`, against a Store port. The error was treating
"needs a port" as "is host capability."

What actually stays two implementations: **the adapter implementations behind
the ports** — every driven adapter, the whole of `rust/host`'s web (2,405),
mint (1,449), journal (1,093) and auth (899) layers, and the era concurrency
protocol. The instrument there is **contract narrowing, not projection**:
`.port` already declares `signal: reply|effect` and a `PortAnswer` list naming
the methods an adapter must answer, and what eventually closes
[0036](decisions/0036-postgres-era-cross-runtime-concurrency-gap-investigated-not-yet-closed.md)
is one declared locking port both runtimes bind — not a bluebook of concurrency.

Two things remain outside every phase and outside the floor framing alike:

- **The "identically wrong" class.** `docs/implemented/rust-experiment.md`:
  "places both runtimes agreed *and were identically wrong*... agreement is not
  correctness." Single-sourcing removes disagreement and does nothing for this.
  It stays the job of `bin/model_check` and the fuzzer's declared properties.
## Suggested order

Interleaved across both tracks, cheapest-and-most-certain first.

1. **B1 — invariants as a table.** Contained, the hard part (the `Expr`) is
   already data, the refusal wording is already single-sourced, and the corpus
   fixtures pin the observable output. Ship it with the nested-VO recursion
   still generated. It also proves the "generated function → static table"
   move on something small before Phase 1 does it on something load-bearing.
2. **Phase 1 — mutations.** The largest drift item: four of the nine incidents,
   and it establishes the `mutation_ops/` convention.
3. **Phase 4 — query/read-model vocabularies.** Two incidents and part of a
   third, and cheap: two vocabulary terms and two conformance specs, no Rust
   interpretation written. No dependency on Phase 1, so it parallelises.
4. **B2 — the reflection spike.** One aggregate, end to end, then decide. Do
   not schedule the rest of it before the spike answers.
5. **Phases 2 and 3, either order.** Neither closes an incident from the
   0040–0052 run. Phase 2 closes the H1 ordering class, which bit once and
   earlier; Phase 3 removes a false guarantee rather than a divergence.

**If only two things get done:** B1 and Phase 1. B1 is the cheapest real
reduction in the tree; Phase 1 is the largest real drift closure.

### Scorecard — Track A, against the nine incidents

| | closed by | count |
|---|---|---|
| mutation ops (0042, 0046, 0047, 0049) | Phase 1 | 4 |
| read-model aggregation (0050, 0052) | Phase 4a | 2 |
| null ordering (part of 0040) | Phase 4b | ~0.5 |
| type bridging (0045, 0051) | **nothing — permanent** | 2 |

Roughly six and a half of nine become structurally impossible. The two type-
bridging incidents are the static-typing tax — resolving an IR `source` to a
Rust type and `Option` depth — and no amount of projection retires them, which
is why Phase 1's own scope note insists that machinery survives.

### Scorecard — Track B, against generated volume

| | addressed by | lines | share of generated |
|---|---|---|---|
| `check_invariants` | B1 | 2,890 | 6% |
| `to_json` / `from_json` | B2 (spike first) | 14,768 | 31% |
| `field` / `as_scalar` / `items` / `find_fielded` | B2 (spike first) | 11,488 | 24% |

B1's reduction is real but bounded. B2's is the large one and is **unproven** —
the size is measured, the feasibility is not, and the `Fielded` trait as it
stands cannot drive either direction of the codec.

### Scorecard against the nine incidents

| | closed by | count |
|---|---|---|
| mutation ops (0042, 0046, 0047, 0049) | Phase 1 | 4 |
| read-model aggregation (0050, 0052) | Phase 4a | 2 |
| null ordering (part of 0040) | Phase 4b | ~0.5 |
| type bridging (0045, 0051) | **nothing — permanent** | 2 |

Roughly six and a half of nine become structurally impossible. The two type-
bridging incidents are the static-typing tax — resolving an IR `source` to a
Rust type and `Option` depth — and no amount of projection retires them, which
is why Phase 1's own scope note insists that machinery survives.
