# Executable Relationship follow-up

## Result

A finite, inspectable instruction language now has a mechanically checked relational interpretation. Its interpreter and its composed graph relation give **exactly the same result for every program and starting configuration** in the Lean model. Two explicit Pizza programs match two frozen ancestral Hecks fixtures in full: final instances, ordered events, and ordered refusals. A separate SQLite runner matches the observed committed-trigger/refused-reaction boundary and a failed transaction boundary. These are executed slices of the reduction, not a general Hecks lowering.

The Pizza executable grammar has **five tags**: `require`, `put`, `append`, `event`, and `commit`. The boundary runner has six tags: `stage_record`, `stage_event`, `stage_outbox`, `commit`, `claim`, and `refuse`. The Lean fragment has `requireAtLeast`, `add`, `emit`, `commit`, `commitFault`, and `reactionRefuse`. `commit` is still an explicit operational instruction. Thus the experiment supports one *denotational* Relationship type, but does not establish one executable primitive. Counting every program as a relation would conceal these tags and their interpreter.

## Lean model

[ExecutableRelationship.lean](ExecutableRelationship.lean) defines a configuration with durable and staged state, pending and committed ordered event lists, a primary status, and a reaction status. Its instruction grammar is finite and takes no function or relation callbacks. `instrRel i` is the graph of `step i`; `programRel` composes these graph relations. `run_realizes_relation` proves `programRel p s t ↔ run p s = t` for every finite program. Separate theorems prove the model's atomic commit update, no durable state or event change on a refused guard, preservation of the accepted primary result when a reaction refuses, and no durable change on the modeled commit fault. `torn_commit_is_not_atomic` constructs a nontransactional adapter that writes state before event failure and proves its result differs from the atomic fault result. Three concrete examples are checked by computation.

The commit theorem is **about a single model step**. It assumes that a physical store can implement that step atomically and durably. It does not prove a SQLite or external-service implementation meets it. The model has no concurrent interleavings, scheduler, actor authority, clock, crash point, or retry protocol.

Command: `LEAN_PATH=work work/lean-4.36.0-darwin/bin/lean outputs/ExecutableRelationship.lean`  
Exit status: `0`; standard error: empty. Exact standard output, also in [executable-lean-check.txt](executable-lean-check.txt):

```text
'ExecutableRelationship.run_realizes_relation' depends on axioms: [propext]
'ExecutableRelationship.commit_atomic_in_model' depends on axioms: [propext]
'ExecutableRelationship.refused_guard_does_not_commit' depends on axioms: [propext]
'ExecutableRelationship.reaction_refusal_keeps_commit' depends on axioms: [propext]
'ExecutableRelationship.commit_fault_rolls_back' depends on axioms: [propext]
'ExecutableRelationship.torn_commit_is_not_atomic' does not depend on any axioms
'ExecutableRelationship.accepted_example' does not depend on any axioms
'ExecutableRelationship.refused_example' does not depend on any axioms
'ExecutableRelationship.reaction_example' does not depend on any axioms
```

The file has no `sorry`, `admit`, or custom axiom. `propext` is a standard Lean axiom. `RelationshipExperiment.olean` was built from the previously checked [relationship model](RelationshipExperiment.lean) in the local `work/` directory to satisfy the import.

## Frozen Hecks comparison

[pizza_relationship_probe.rb](pizza_relationship_probe.rb) defines five instruction tags and a finite expression grammar: constant, argument lookup, candidate-field lookup, object construction, nonempty test, and greater-or-equal test. There is no arbitrary user callback. The three supported commands (`CreatePizza`, `AddTopping`, `Purchase`) are lowered to explicit instruction lists written independently of the fixture's expected output. Every command starts with a copied candidate state and a pending event list; `commit` publishes both. A failed `require` stops the command and discards those pending changes.

The runner read two frozen JSON fixtures from ancestral Hecks commit `8a8a2699961a00c54fa6858fa5d7d52bd47d084d` and compared the full `expect` object. Exact output in [pizza-relationship-results.json](pizza-relationship-results.json):

```json
{
  "instruction_tags": ["require", "put", "append", "event", "commit"],
  "results": [
    {"fixture": "accepted_pizza_lifecycle", "matched": true},
    {"fixture": "given_unmet_leaves_the_record_purchasable", "matched": true}
  ]
}
```

Exit status: `0`; standard error: empty. The first fixture covers create, topping append, purchase transition, and event order. The second covers a no-toppings refusal, an underpayment refusal, lack of state/event changes on either refusal, and eventual successful purchase of the same pizza. These are **2 of 52** frozen semantics fixtures. The earlier 52/52 result checked ancestral Hecks against its oracle, not the reduced interpreter.

The Ruby and Lean interpreters are separately specified; there is no proof that they implement one another. The Pizza lowering does not parse Bluebooks, handle arbitrary commands, distinguish fault from refusal, or cover queries, saga selection, authorization, outbox delivery, or physical commit. It uses domain-specific data in three explicit programs. The current result is therefore a genuine narrow conformance check, not a claim of full corpus expressiveness.

## Commit and reaction boundary

[boundary_relationship_probe.rb](boundary_relationship_probe.rb) uses a separate finite program and an isolated SQLite database. Its `commit` instruction inserts a record, event, and pending outbox row inside one SQLite transaction. `claim` and `refuse` run afterward. The probe first commits an order and then refuses its reaction; it compares the primary outcome, record, event name, and outbox row with [Hecks's isolated reaction run](outbox-boundary-recheck.json). That Hecks run was repeated in this turn and produced the same output as the earlier sample.

The second run injects `disk full` **after the record insert but before the event insert**. The model's transaction rolls back. The probe closes and reopens its database and counts zero records, events, and outbox rows. It compares this boundary with [Hecks's repeated SQLite fault run](outbox-sqlite-recheck.json), which likewise left no order or new event/outbox row. The outputs are narrower than full runtime equivalence: the model does not reproduce the full Hecks reaction object, scheduler, retry state, or adapter API. Exact model output is in [boundary-relationship-results.json](boundary-relationship-results.json):

```json
{
  "reaction_boundary_matches_hecks": true,
  "fault_rollback_matches_atomic_law": true,
  "fault_boundary_matches_hecks_sqlite": true,
  "reopened_database": {"records": 0, "events": 0, "outbox": 0},
  "instruction_tags": ["stage_record", "stage_event", "stage_outbox", "commit", "claim", "refuse"]
}
```

The model run exited `0` with empty standard error. Both repeated Hecks probes exited `0`; the ancestral checkout remained clean. This confirms the sampled boundary behavior and demonstrates precisely where physical substrate matters: the SQLite transaction implements atomicity. A relation can *specify* the all-or-nothing outcome but cannot itself make separate writes atomic. The Lean torn-write counterexample rules out treating that obligation as automatic.

## Next falsification target

Next, replace the two independently written Ruby interpreters with one typed, finite grammar that covers the Pizza and boundary cases, and prove a correspondence between its executable semantics and the Lean transition relation. Add actor and World capability tokens and test authority preservation under composition. Then stress concurrent writes, crash timing, and retry/claim behavior against Hecks. The current explicit SQLite transaction is a necessary substrate contract, not a reduction of physical atomicity to pure relation composition.

No ancestral source was changed. No push, tag, release, or publication occurred.
