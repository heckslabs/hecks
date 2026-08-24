# Fuzzer property expansion: five gaps, scoped and ordered

Five research passes over `META_DOMAIN_KNOWN_GAPS` (`spec/fuzzing/meta_domain_coverage_spec.rb`),
each reading the real enforcement code, the real generator, the real corpus, and — for two of
them — running a live probe against a real domain rather than reasoning from the code alone. This
is the plan that came out of it: what's real, what's blocked on what, and the order that gets the
most value fastest without building anything the later items would have to undo.

**One finding changes the shape of the whole plan**: `Entity#identified_by` is not an untested
property. It's a confirmed, live, reproducible bug — two entities can silently collide on
identity today, and the collision corrupts more than it looks like. That moves to the front,
ahead of every property, because it's not "add a test," it's "there's a hole."

## Priority order

| # | Item | Size | Blocked on |
|---|---|---|---|
| 1 | **Fix + prove: entity identity collision** | small (fix) + small (property) | nothing — ready now |
| 2 | `stored_records_satisfy_declared_invariants` | small | nothing — ready now |
| 3 | `group_by_matches_recompute` | small | nothing — ready now |
| 4 | Fix: `QueryInterpreter` never applies `offset` | small | nothing — ready now |
| 5 | `paging_offset_partitions_correctly` | small | #4 |
| 6 | `lifecycle_guard_and_given_violations_are_refused` | medium | one `Replay` extension |
| 7 | `authorize_scopes_or_refuses` | medium | a generator fix, or a hand-built ask |
| 8 | `dispatch_binding_fidelity` (+ `Policy#with_spec` free alongside) | medium | one new, additive `Replay` log |
| 9 | `mutations_match_recompute` | large | fixture packaging + corpus content + a `Replay` extension |

Items 1–5 need nothing but the fix itself and a property body — do these first, in any order,
they're independent. Items 6–8 each need one bounded, precedented extension to `replay.rb` before
the property can be written — do these next. Item 9 is last on purpose: it's the only one where
the *language feature being tested has no real user* — everything else is proving something a
real corpus domain already does; #9 would be proving something only a disconnected test fixture
does, until that's fixed too.

---

## 1. Fix + prove: entity identity collision (real bug, confirmed live)

**The gap note undersold this.** `META_DOMAIN_KNOWN_GAPS["Entity#identified_by"]` calls it an open
question — whether an entity's own identity-collision handling matches the aggregate's. It doesn't
match. Confirmed by dispatching against real banking, twice, live:

```
=== Visit: dispatching LogVisit TWICE with the SAME date+sequence ===
NO ERROR RAISED on second identical LogVisit — visits.size = 2, both identical

=== KeyIssuance: dispatching IssueKey TWICE with the SAME serial ===
NO ERROR RAISED on second identical IssueKey — keys.size = 2, both identical
```

Then dispatched `SafeDepositBox.KeyIssuance.Return` against the box holding the duplicate pair —
`element_of`'s `find_index` matches the *first* match and mutates only that one. **The second
duplicate becomes permanently unaddressable** — no command can ever name "the second KEY-1" again.
This is worse than a duplicate row: it's silent duplication plus silent future misrouting.

**Root cause**: `CommandInterpreter#hydrate` checks `AlreadyExists` for an aggregate's own creating
command (`repository.find(id)` before building a new `Instance`) — this was itself a real,
previously-fixed bug, per that file's own comment trail. The entity path never got the matching
fix. `MutationApplier#entity_element` (`lib/hecks/runtime/command_interpreter/mutation_applier.rb:174-189`)
has two branches minting/accepting a new element's identity, and **neither checks the sibling list
for a collision**:
- auto-mint branch (`current.size + 1`) — safe today only because no real domain ever `remove:`s
  from an entity list (checked — none do), so nothing shrinks the array between mints
- caller-supplied branch — used whenever the identity field is in the append's own field map, or
  the entity has a **composite** identity (`identified_by` is `nil` for those, per
  `Runtime::Identified#derive_identity` — this branch is unconditional for composite identities)

Real corpus sites hitting the unchecked branch: `SafeDepositBox::Visit` (composite `date`+`sequence`)
and `SafeDepositBox::KeyIssuance` (single, caller-supplied `serial`).

**The fix**: at the one chokepoint, `MutationApplier#entity_element` — when identity fields are
caller-supplied (or unconditionally, for composite identities) — check `Array(current)` for an
existing element whose identity-path values already match `fields`, and raise a new
entity-scoped `AlreadyExists` refusal (a `RefusalWording` template parallel to `creating_duplicate`)
before appending. Same shape as the aggregate-level fix, one level down. Small, understood, one
method.

**Then the property**: dispatch a real creating aggregate command twice with identical
entity-identity args (`LogVisit`, `IssueKey`) and assert the second raises. Auto-minted entities
(`LedgerEntry`, `Withdrawal`) serve as the negative control — they should never collide and the
property must not spuriously flag them.

*Second-order, not urgent*: the auto-mint scheme's safety depends on no domain ever pairing an
entity list with `remove:`. Nothing enforces that today — worth a one-line note wherever the fix
lands, not a blocker.

## 2. `stored_records_satisfy_declared_invariants` (closes `Aggregate#invariants`)

No new plumbing. `history[:instances]` (final state) + `history[:bluebooks]` are already returned
by `Replay.call` — for every stored record, re-evaluate its aggregate's declared `invariants`
against its own state via `Bluebook::Expression::Evaluator.call` directly. Any stored record
failing a declared invariant is proof a violating write was never refused.

Real target: `Account`'s own `invariant("the balance never goes negative") { balance.cents >= 0 }`.

## 3. `group_by_matches_recompute` (closes `ReadModel#group_by`, contributes to `ReadModel#options`)

Same independent-recomputation shape `aggregation_matches_recompute` already uses for
`count`/`median` — extend it to grouped aggregation. Reachable today: `AccountsByKind`
(`group_by :kind, :number`, rootless) is always generator-eligible and already gets dispatched
successfully; nothing currently checks the result.

## 4. Fix: `QueryInterpreter` never applies `offset` (prerequisite for #5)

Real, confirmed bug, independent of the PR #324–326 limit/offset fix (that one was
native-vs-native, in `Ports::Query::InMemory`; this is native-vs-**reference**, in
`Runtime::QueryInterpreter#interpret`/`#reference_interpret` — neither ever reads
`declared.offset`, confirmed by grep returning nothing). `reference_query` is the fuzzer's own
oracle path (`query_answers_match_reference`'s comparison target) — so any declared `Query` with
`offset` set and enough matching rows will disagree between `runtime.query` and
`runtime.reference_query` **today**, latent only because the standard 5-seed×25-step battery
hasn't reliably produced ≥2 active `ATMCard`s within budget yet. Real corpus site already exists:
`ATMCard.ByFee` (`limit 3; offset 1`).

Fix first — otherwise item #5's own property "finds" a bug that's in the oracle's reference
implementation, not anything a real caller would ever see.

## 5. `paging_offset_partitions_correctly` (closes `Query#options`)

Once #4 is fixed, `query_answers_match_reference` already covers offset for free (it's just
another field the native/reference comparison walks) — decide whether that's enough or whether a
dedicated property proving the "pages partition the whole set, no gaps, no overlaps" claim
(generalizing `spec/query_paging_agreement_spec.rb`'s hand-written proof into a replay property)
is worth adding on top. Either way, small once #4 lands.

*Note for whoever builds this*: `offset`/`nulls`/`cursor` are declared by the `Paging` sub-language
now (`lib/hecks/language/bluebook/attaches/paging.bluebook`, ADR 0026/S15), not the core
`syntax.bluebook` — confirmed this changes nothing about the Ruby runtime (`DSL`/`Ports::Query`/
`QueryInterpreter` are all untouched by that move), but worth a one-line comment so a future reader
isn't confused hunting for the grammar rows in the wrong file.

*Explicitly out of scope, confirmed dead or nonexistent — do not write properties for these*:
`cursor` (refused unconditionally at build, no interpreter implements it); `consistency`,
`freshness`, `use_index` (no `DSL` method exists for any of them — they're prose in
`behavior.bluebook`'s comments describing an aspirational shape, never real declarable grammar).
`inspect_query` is thin enough to be a construction-guarantee note rather than a property (no
adapter in the fuzzer's Memory-only world implements it).

## 6. `lifecycle_guard_and_given_violations_are_refused` (closes `Command#from`, `Aggregate#preconditions`)

Needs one bounded `Replay` addition: a per-step pre-dispatch snapshot of the acted-on subject,
mirroring the already-existing `fan_out_snapshot` idiom (taken, used, discarded, once per step).
The property then calls `Admissibility.enforce_lifecycle_guard`/`enforce_givens` **directly**
against the reconstructed pre-state and compares its verdict to what actually happened —
independent recomputation, not grading production against itself. `Aggregate#preconditions`
closes for free alongside this — it compiles into the exact same `Rule` struct a command's own
`givens` already are (confirmed against `aggregate_builder.rb`), so no separate check is needed.

Real targets: `Account.Debit`/`CloseAccount` (`from:` guards), `Credit`/`Debit`/`FreezeAccount`
(the named-once `given("customer is active")` precondition).

*Rejected alternative, and why*: actively generating sequences that deliberately violate an
invariant/given was considered and rejected — for lifecycle `from:` it's a bounded generator
addition, but for invariants/givens it requires inverting an arbitrary `Bluebook::Expression` AST
into a counter-example, a general constraint-solving problem this codebase has no machinery for
anywhere. Passive audit (this design) reuses the "two engines, compared" pattern already
established by the query and fan-out oracles, and directly targets the real defect class named
in scoping — a call-site that silently stops calling the enforcement method — without inventing
a new subsystem.

*Found along the way, worth a separate note*: `enforce_lifecycle_guard`'s own refusal wording is
hand-rolled inline rather than routed through `RefusalWording`'s single-source-of-truth table,
unlike every other `LifecycleRefused` site. Not blocking, but any string-matching this property
(or anything else) does against that message needs to know there are two shapes, not one.

## 7. `authorize_scopes_or_refuses` (closes `Query#options`, `ReadModel#options`)

Claim: every successful answer's tenant field matches the arg given; every ask missing a required
`tenant:` refuses. Currently **unreachable on the success path** by the generator —
`SafeDepositBox.Rented` declares zero attributes of its own (only `where`/`order_by`/`authorize`),
so `build_query_step` always calls it with `{}`, and `TenantScope.apply` refuses every generated
attempt unconditionally. Same shape as the PR #325 precedent (generator never asked read-models
until someone added it) — here it never successfully asks an authorized query at all.

Two ways to close it: extend the generator to supply a `tenant:` arg for `authorize`-bearing
queries (the more thorough fix, benefits every future property touching this query), or write the
property against a synthetic/hand-built ask that bypasses the generator (faster, narrower). Decide
at build time based on how much the generator fix would cost versus how much broader coverage it
buys.

## 8. `dispatch_binding_fidelity` (closes `Handler#dispatches`, `Dispatch#command_name`,
`Dispatch#with_spec`, and — nearly free alongside — `Policy#with_spec`)

**The one landmine to avoid, found by reading the code, not the comment**: the obvious plumbing
(add an `args:` field to the existing `saga_log`/`reaction_log` entries `Replay` already returns)
would break `spec/rust_conformance_spec.rb`'s exact byte-for-byte equality check between Ruby's
and Rust's saga/reaction logs on every fixture exercising a saga dispatch — `orchestrate.rs` ports
that exact shape today and doesn't carry the new field. **Do not touch the existing logs.**

Instead: a new, additive, Ruby-only `registry.saga_dispatch_log` — `SagaInterpreter#deliver_saga_dispatch`
already computes `dispatch_args(...)` before calling `@door.reenter`; push one entry there
(`process_manager:`, `instance:`, `dispatch:`, `on:`, `args:`). ~6 lines across
`registry.rb`/`saga_interpreter.rb`/`dispatcher.rb`/`replay.rb`, fully additive, zero Rust surface,
zero risk to conformance. `Policy#with_spec` is the same pattern one file over
(`policy_interpreter.rb#trigger_args`) — worth scoping together since the plumbing is nearly free
the second time.

The property re-derives `dispatch_args`'s own 3-tier resolution (literal → correlation-head →
current-event-payload → saga-memory-fallback) independently against the captured `args`, and flags
a mismatch. Real corpus targets are rich and varied: `Settlement` (mixed literal/event/memory
bindings across three legs plus a compensation leg that deliberately omits a field the forward leg
carried), `ExternalSettlement`, `Onboarding` (no compensation leg, by design).

**What this would have caught**: exactly the class of bug PR #325 found one level over — a wrong
argument binding on a fan-out dispatch that produces a perfectly normal-looking log entry
(`delivered: true`) and would only ever surface as a downstream assertion failure, if it surfaces
at all.

## 9. `mutations_match_recompute` (closes `Command#mutations`) — last, and the big one

Turned out to be the largest of the five, for reasons that only showed up once someone actually
went looking:

- **No real corpus entity anywhere uses `append`/`remove`/`multiply`/`clamp`.** Every real
  aggregate-owned mutation is aggregate-scoped (`Account.Credit`'s `:ledger`, `LogVisit`'s
  `:visits`, etc.) — the only entity-owned use of these ops in the whole repository is
  `spec/fixtures/entity_list_mutations.bluebook`, a dedicated test fixture.
- **That fixture isn't packaged as a bootable domain** — no `.hecksagon`, not laid out under
  `examples/`, so `Replay.call`/`SequenceGenerator.generate` can't point at it as-is.
- **`Replay` has no per-step before/after mutation trace.** Every other property reads final
  `history[:instances]`; this one needs a delta (what changed, by what op, at which step) the way
  `aggregation_matches_recompute` never had to ask for, because count/median are pure functions of
  final state and mutations aren't.

None of this is the generator's fault — it's already structurally ready to dispatch entity commands
(confirmed: `Catalog`/`Picker`/`StepBuilder` all already walk `aggregate.entities`). The corpus and
`Replay` are the real blockers.

**Path to unblock, roughly in order**: package `entity_list_mutations.bluebook` as a proper mini
domain (add a `.hecksagon`; Memory-default, no `.world` needed) or add a real entity-owned mutation
to an `examples/` domain instead (heavier, touches production example content — probably worse);
extend `Replay` with the per-step before/after trace; write four small independent-recompute
functions (one per op); update `FEATURE_COVERAGE`/`META_DOMAIN_KNOWN_GAPS`.

*Found along the way, worth a separate note regardless of when this lands*: `clamp` has no
`current ||= 0` fallback the way `multiply`/`increment` do (`CommandRules::Arithmetic`) — a
phantom (never-set) numeric field hits `TypeMismatch` on first `clamp` where the other arithmetic
ops would silently treat it as zero. A real asymmetry in shared code, not entity-specific.

---

## Summary of real defects found while scoping (independent of whether/when each property lands)

1. **Entity identity collision** (§1) — live bug, needs a runtime fix, not just a test. Highest
   priority regardless of the rest of this plan.
2. **`QueryInterpreter` never applies `offset`** (§4) — live, latent bug in the fuzzer's own
   reference-interpreter path (not anything a real caller sees, but blocks §5 honestly).
3. **`enforce_lifecycle_guard`'s wording bypasses `RefusalWording`'s table** (§6) — cosmetic/
   consistency, not urgent, but a real inconsistency in an otherwise disciplined codebase.
4. **`clamp` has no phantom-field fallback** (§9) — real asymmetry in shared arithmetic rules,
   independent of entities.

None of these were the target of the investigation that found them — all four surfaced purely
from reading the real enforcement code closely enough to scope a property honestly, which is
exactly the track record this whole arc (#324–326, and now this) has established: scoping a
property properly means reading code closely enough that it tends to find something.
