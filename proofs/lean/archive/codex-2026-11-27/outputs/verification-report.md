# Crystal Era formal verification experiment

## Result

The abstract sequential algebra is machine checked in [CrystalExperiment.lean](CrystalExperiment.lean) with Lean 4.36.0. It proves identity, associativity, successful invariant preservation, all-outcomes invariant preservation, and observational equivalence congruence. Both invariant theorems cover arbitrary finite lists by induction. A candidate fusion is safe in a surrounding sequence **if its full outcome is equivalent for every input**. The experiment does not establish that any actual Hecks optimization meets this premise.

The next experiment defines the proposed two constructors explicitly: a pure `guard` that can pass, refuse, or fail; and a total `change` that updates state and emits an ordered trace. Lean verifies invariant preservation for lists of these constructors. Concrete Pizza and Pipeline lifecycle observations match small, independently written models using those two constructors. **This is evidence of fit for the sampled direct command paths, not proof that the two constructors are a complete Hecks algebra.**

A reaction boundary exposes a missing law. An isolated Hecks command succeeded while a policy reaction refused and its outbox row became `refused`. Naively composing the command and reaction with the same short-circuit `seq` changes the whole result to refusal. Lean proves that mismatch. The refined model therefore separates the committed primary outcome from delivery rows and their statuses. Lean checks that delivery leaves the primary outcome intact, appends to the observation trace, and does not replay a claimed or settled row by default. It also proves invariant preservation across commit and delivery **when the primary command and every consumer preserve that invariant**. These are theorems about the refined model; the runtime checks below are limited behavioral evidence.

The model also proves concrete counterexamples: a fusion can lose an effect before refusal, change failure into refusal, or reorder effects while leaving the resulting state unchanged. A failed operation can carry an external write and a changed state, so failure atomicity is not an algebraic consequence.

The earlier “six obligations” comparison was illustrative, not a measured CI result or a universal limit. Once the general composition laws are proved, increasing composition **depth alone** does not require a new law for each sequence. The remaining work still grows with the number of distinct primitive transformations, invariants, observation boundaries, and proposed fusions. Every primitive must discharge its premises, and each fusion needs its own equivalence proof. This experiment establishes the depth-independent induction theorem; it does not show that total Hecks CI checks will fall below ten.

## Abstract semantics

`Step S E C` is a deterministic total function from state `S` to one of `success`, `refusal`, or `failure`. Every outcome carries a resulting state and an ordered list of events; refusal and failure additionally carry a code. `seq f g` runs `g` only if `f` succeeds, concatenates traces in order, and preserves any refusal or failure from `f`. `ObsEq` means exact equality of status, state, code, and ordered trace for every input state. This is a deliberately strong observation relation.

`Preserves` requires the invariant after success. `PreservesEveryOutcome` requires it after success, refusal, and failure, using the state carried by each outcome. The finite-chain theorems require the corresponding preservation premise for **each** primitive step. They do not prove that a given Hecks command satisfies that premise.

## Exact proof checker output

Command: `work/lean-4.36.0-darwin/bin/lean outputs/CrystalExperiment.lean`  
Exit status: `0`

```text
'CrystalExperiment.seq_associative' depends on axioms: [propext]
'CrystalExperiment.preserves_chain' depends on axioms: [propext]
'CrystalExperiment.preserves_every_outcome_chain' depends on axioms: [propext]
'CrystalExperiment.fusion_in_context' depends on axioms: [propext]
'CrystalExperiment.unsafe_fusion_loses_effect' does not depend on any axioms
'CrystalExperiment.atoms_preserve_every_outcome' depends on axioms: [propext, Quot.sound]
'CrystalExperiment.pizza_valid' depends on axioms: [propext, Classical.choice, Quot.sound]
'CrystalExperiment.pipeline_land_then_push' depends on axioms: [propext, Classical.choice, Quot.sound]
'CrystalExperiment.linear_reaction_composition_misclassifies_command' depends on axioms: [propext]
'CrystalExperiment.success_then_refusal_is_refusal' depends on axioms: [propext]
'CrystalExperiment.delivery_preserves_primary' depends on axioms: [propext]
'CrystalExperiment.commit_then_delivery_preserves_invariant' depends on axioms: [propext]
'CrystalExperiment.delivery_preserves_trace_prefix' depends on axioms: [propext, Quot.sound]
'CrystalExperiment.pending_redrive_delivers' depends on axioms: [propext]
'CrystalExperiment.committed_primary_with_failed_reaction' depends on axioms: [propext]
'CrystalExperiment.claimed_is_not_replayed_without_evidence' depends on axioms: [propext]
'CrystalExperiment.primary_refusal_has_no_delivery_row' depends on axioms: [propext]
'CrystalExperiment.fanout_preserves_primary' does not depend on any axioms
'CrystalExperiment.fanout_preserves_invariant' depends on axioms: [propext]
'CrystalExperiment.fanout_order_is_observable' does not depend on any axioms
'CrystalExperiment.different_aggregate_remains_blocking' depends on axioms: [propext, Classical.choice, Quot.sound]
'CrystalExperiment.same_aggregate_alternative_excuses_refusal' depends on axioms: [propext,
 Classical.choice,
 Quot.sound]
'CrystalExperiment.different_event_does_not_excuse_refusal' depends on axioms: [propext, Classical.choice, Quot.sound]
'CrystalExperiment.blocker_cannot_be_decided_from_row_alone' depends on axioms: [propext, Classical.choice, Quot.sound]
'CrystalExperiment.full_blocker_examples' depends on axioms: [propext, Classical.choice, Quot.sound]
'CrystalExperiment.missing_event_identity_can_change_classification' depends on axioms: [propext,
 Classical.choice,
 Quot.sound]
```

This is the complete standard output in [lean-check.txt](lean-check.txt); standard error was empty. `propext`, `Classical.choice`, and `Quot.sound` are standard Lean axioms. The proof contains no `sorry`, `admit`, or custom `axiom`. Checker version output was:

```text
Lean (version 4.36.0, x86_64-apple-darwin24.6.0, commit 611c117bfaf7b7ae1cfcf246ce6fba31e8f509e9, Release)
```

The downloaded release archive's SHA-256 was `476f9dcf7bee6a070e39a6b15cab7ada48b0086bd91d6e61aa1a454d3da409ce`, matching the GitHub release metadata. The checker and its archive remain under the local `work/` directory; no system installation was made.

## Ancestral Hecks probe

I read the local checkout at `/Users/christopheryoung/Projects/hecks`, commit `8a8a2699961a00c54fa6858fa5d7d52bd47d084d`, and ran [hecks_probe.rb](hecks_probe.rb) against a temporary copy of its Pizzas example. The source checkout was not changed. The probe submitted three `CreatePizza` steps: valid `First`, invalid empty name, valid `Second`. It asserted both valid records and both ordered `PizzaCreated` events were present, with exactly one refusal.

Command: `ruby -I /Users/christopheryoung/Projects/hecks/lib outputs/hecks_probe.rb`  
Exit status: `0`

Exact output is in [hecks-probe.json](hecks-probe.json). The observed refusal was `PizzaName.value must match [^ \\t\\n\\r], got ""`.

This reveals an important semantic boundary: Hecks `StepRun.execute` records a refused step and **continues** to the next script step. The abstract `seq` operator short circuits on refusal and failure. The Lean theorem therefore applies to a candidate command or transaction composition with that short-circuit contract; it does not apply directly to `StepRun`'s continue-on-error script semantics. The probe also does not test failure after an external write, optimized fusion, or parity between Ruby and generated Rust.

## Two-constructor tests against Hecks

The [Pizza probe](two_construct_probe.rb) copied the Pizzas example into a temporary directory and compared a hand-written guard/change program to five actual dispatches: valid creation, invalid name, duplicate identity, wrong role, and valid creation after refusals. All five matched on primary outcome kind, refusal code and stage, new event names in order, and persisted record identities. The exact observations and matches are in [two-construct-pizza.json](two-construct-pizza.json). The model did not compare every field of the returned Pizza state, the wording of errors, or the internal dispatch trace.

The [Pipeline probe](pipeline_probe.rb) copied the standalone Pipeline domain into a temporary directory. Its five cases—plan, early push refusal, land, push, verify—matched a second guard/change model on outcome kind, refusal code and stage, event names, lifecycle stage, and pushed commit value. See [two-construct-pipeline.json](two-construct-pipeline.json). The checker emitted one unrelated `PullRequest#state` warning on standard error, captured in [pipeline-stderr.txt](pipeline-stderr.txt). This probe exercises direct lifecycle commands; it does not exercise Pipeline's cross-domain policies or real Git operations.

The [reaction boundary probe](outbox_boundary_probe.rb) booted a small Shop domain in a temporary directory. The first `Order.Place` succeeded and emitted `OrderPlaced`, while its `RecordOrder` policy reaction refused and its outbox row became `refused`. A second `Order.Place` also succeeded while an injected consumer exception made its row `failed`. Exact output is in [outbox-boundary.json](outbox-boundary.json), with the runtime's refusal notice in [outbox-stderr.txt](outbox-stderr.txt). The Lean theorems `dropping_reaction_is_observable` and `linear_reaction_composition_misclassifies_command` show why omitting the reaction or applying ordinary short-circuit composition loses this behavior.

The [SQLite outbox probe](outbox_sqlite_probe.rb) ran in a temporary directory with its own database. An injected `Interrupt` before claim left a committed order, `OrderPlaced`, and a `pending` row; explicit redrive delivered the reaction and created the ledger record. An injected `Interrupt` after claim left a committed second order and a `claimed` row; ordinary redrive returned no delivery, and a fresh boot left that row claimed. An injected `record_event` error for a third order left no order, new event, or new outbox row. The script asserts each observation and exited `0`; exact output is in [outbox-sqlite.json](outbox-sqlite.json). These are targeted checks of this local Hecks checkout, not a proof that its persistence implementation is atomic for all adapters or crash points.

The [fanout probe](fanout_probe.rb) ran fresh temporary Shop domains with two policies. One policy refused; its sibling succeeded. In the first two runs, reversing declaration order reversed reaction and outbox row order, while the primary `Order.Place` still succeeded and event names were `OrderPlaced, AuditRecorded` in both. In a third run, the successful sibling targeted a different command on the **same aggregate** as the refusal. The result still listed the refused reaction, but `blocking_reactions` became empty. A success on a different aggregate left the refusal blocking. Without waiting, the CLI returned status `0` in both setups; with `--wait`, it returned `1` for the blocker and `0` for the answered alternative. Exact output is in [fanout-observations.json](fanout-observations.json); the expected refusal notices are in [fanout-stderr.txt](fanout-stderr.txt).

Lean checks `fanout_preserves_primary`, `fanout_preserves_invariant` under per-consumer premises, and `fanout_order_is_observable`. It also checks a **restricted** blocker relation: a delivered different command on the same aggregate excuses a refusal only when both answer the same event instance. The concrete theorems `different_aggregate_remains_blocking` and `same_aggregate_alternative_excuses_refusal` match the sampled runs. `different_event_does_not_excuse_refusal` checks the event-identity condition stated in the source rule, but this probe did not independently exercise that condition in Hecks. Hecks also has exceptions for already-existing records, answered asks, and held stores; those are absent from this restricted relation.

The [classifier probe](reaction_classifier_probe.rb) exercised the actual `ReactionOutcome` implementation directly with ten small synthetic reaction sets. It confirmed the same-event alternative, different-event and different-aggregate blockers, duplicate-creation excuse, answered-ask excuse, held-store excuse, and separate defect reporting. It also confirmed that when an event identity is missing, Hecks falls back to event **name** for the alternative check. Exact output is in [reaction-classifier.json](reaction-classifier.json). These are direct tests of the classifier, not end-to-end dispatches for each case.

Lean's wider `ReactionEvidence` model reproduces those cases via `full_blocker_examples` and `missing_event_identity_can_change_classification`. It treats the duplicate-creation exception as a Boolean certificate. The real implementation derives that fact by matching the refusal message against a template and the creating command and aggregate name. A proof over typed refusal codes alone would not establish parity with this behavior. The event-identity fallback also means a proof must state whether it covers local rows with identity or remote rows where only an event name is available.

The general Lean law `success_then_refusal_is_refusal` shows why ordinary short-circuit composition cannot represent a successful primary dispatch followed by a refused reaction while preserving both statuses. `blocker_cannot_be_decided_from_row_alone` shows that blocking classification is relational: the **same** refused row is blocking or excused depending on a sibling. Any candidate reduction must retain this fanout context and the caller's wait policy as observable behavior. These are scoped impossibility results for the specific guard/change plus short-circuit design, not a proof that no two-construct algebra is possible.

This is the current decision on the two-constructor proposal: **promising for direct command stages, but insufficient with only short-circuit composition**. The added commit/delivery phase handles the sampled refused, failed, pending, claimed, and ordered sibling outcomes. Blocking classification adds a relation over the *whole* set of reactions and the event they answered; it also uses duplicate wording and an identity fallback. It affects the caller's `--wait` status. These are semantic rules even if an implementation eventually expresses their bookkeeping with guards and changes. Whether they can be derived from two non-opaque constructs remains open. The model treats `commit` as one atomic transition; the SQLite probe checks one rollback path, but no refinement proof connects all Hecks commit paths to that assumption.

There is also no minimality result. `guard` and `change` take arbitrary host functions, which can conceal parsing, reference lookup, persistence, and scheduling. Counting constructor names alone does not prove that Hecks has only two irreducible operations. A genuine reduction must expose those functions' effect and failure contracts and prove that every relevant runtime step lowers to them.

## Limitations and next proof obligations

1. No actual Hecks runtime function was translated into Lean or proven equivalent to `Step`. The Pizza and Pipeline runs are narrow behavioral probes, not refinement proofs.
2. A total deterministic state function omits nondeterminism, concurrency, retries, time, outside services, and unbounded reactions. The refined execution record distinguishes a committed primary outcome from delivery status, but it does not model the caller receiving no response after a crash, claim age, scheduling, repeated retries, or multiple consumers. The two-constructor `change` is a total function, so modeling a fault during a real write needs additional semantics. Authority is only representable if included explicitly in state or events.
3. `ObsEq` compares every modeled field. A real World may expose a different observation boundary; that boundary needs a declared projection and a congruence proof.
4. Fusion still needs a per-candidate proof that its full outcome matches the original for every permitted input. Comparing final states or passing selected examples is insufficient.
5. The runtime probe's `StepRun` reports all `StandardError` exceptions as `refusals`, so it cannot by itself establish the Lean distinction between domain refusal and runtime failure.

No pushes, tags, releases, or publication occurred.
