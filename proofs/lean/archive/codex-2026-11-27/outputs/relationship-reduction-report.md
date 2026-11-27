# Crystal Era: can Relationship be the semantic core?

## Decision

**A single relation is a valid denotational vocabulary, but a one-construct Hecks algebra has not been established.** Lean proves that predicates embed as identity-preserving relations and that relational composition has identity, associativity, congruence, and inductive invariant preservation. It also proves two limits: equal immediate observations need not survive later composition, and two implementations can both refine the same permissive relation while producing different visible results. These are counterexamples to two tempting shortcuts, not to every possible relationship-only architecture.

The ancestral Ruby runtime matched **52 of 52** frozen Bluebook semantics fixtures. This is a baseline check of Hecks itself. **No fixture has been translated into, or run by, the relationship-only model.** The existing [guard/change report](verification-report.md) and its probes cover additional Pizza, Pipeline, outbox, and reaction behavior, but that earlier candidate was an experimental substitute for the original Condition/Relationship proposal.

## Mathematical precedent and fit

| Formalism | Direct contribution | Additional assumption for Crystal Era |
|---|---|---|
| [Tarski's calculus of relations](https://www.cl.cam.ac.uk/teaching/1213/Databases/Tarski_1941.pdf) | Identity and associative relational composition supply the denotational core. A predicate can be embedded as a subidentity relation. | A carrier type and an interpretation of each declared relation are still needed. Arbitrary `A → B → Prop` can hide an entire runtime. |
| [Category theory](https://pages.jh.edu/rrynasi1/FoundationsOFMath/Literature/Mac_Lane1971CategoricalAlgebra%2BSet-TheoreticalFoundations.pdf) | Objects/types and composable morphisms explain the typed input/output boundaries. A monoidal product can express independent composition when the needed interchange law holds. | Category laws alone say nothing about failure, persistence, scheduling, or whether two operations are independent. |
| [Nested graph conditions](https://uol.de/f/2/dept/informatik/ag/fs/fs-pub/mscs-HP09.pdf) and [adhesive categories](https://www.numdam.org/item/10.1051/ita%3A2005028.pdf) | Give precise structural conditions and a framework for double-pushout graph rewriting. This is the closest precedent for “relationships are structure; nodes are provisional.” | Specify the graph category, matching, dangling-edge rules, identity policy, and which rewrites preserve World invariants. A graph relation alone does not choose a rewrite. |
| [Park's concurrency semantics](https://wrap.warwick.ac.uk/id/eprint/47224/1/WRAP_Park_cs-rr-035.pdf) and [Milner's CCS](https://link.springer.com/book/10.1007/3-540-10235-3) | Labeled transitions, interaction, and behavioral equivalence motivate comparing future behavior, not merely current output. | Declare visible labels, hidden steps, fairness, and the observation boundary before claiming bisimulation or contextual equivalence. |
| [Petri nets and open Petri nets](https://arxiv.org/abs/1808.05415) | Enabling, token consumption, concurrency, and composition across boundaries are useful models for delivery and resource use. | Token accounting, scheduler, and durability must be specified; ordinary set relations do not provide them automatically. |
| [Linear logic](https://girard.perso.math.cnrs.fr/linear.pdf) | Resource-sensitive proof rules offer a way to prevent accidental duplication or disposal of a one-use capability or delivery claim. | Choose which resources are linear and connect proof rules to actual storage and transport. |
| [Rewriting logic](https://experts.illinois.edu/en/publications/conditional-rewriting-logic-as-a-unified-model-of-concurrency/) | Conditional rewrite rules can describe concurrent state transitions and their composition. | Its rule language and execution strategy are substantive structure; calling every rewrite a relation does not remove them. |

These are mathematical precedents, **not** proofs that Crystal Era and any cited formalism are equivalent. Open-system composition is promising for sovereign Worlds, but an interface between Worlds also needs explicit protocol, identity, authority, withdrawal, and failure rules. A QR invitation can be modeled as a relation between invitation states; the physical scan and delivery remain environmental actions.

## Candidate algebra and exact formal result

The checked model defines `Rel A B := A → B → Prop`, `identity a b := a = b`, and `(r ; q) a c := ∃ b, r a b ∧ q b c`. A condition `P : A → Prop` becomes `condition P a b := a = b ∧ P a`; a query `f : A → B` becomes its graph `f a = b`. This expresses *allowed* transitions, not an execution algorithm. `RelEq` is pointwise equivalence of the full input/output relation.

[RelationshipExperiment.lean](RelationshipExperiment.lean) contains mechanically checked proofs of identity on both sides, associativity, congruence of composition under `RelEq`, satisfaction and non-mutation of an embedded condition, conjunction of conditions via composition, single-valued function graphs, preservation under two relations, and preservation through any finite list when **each** member preserves the invariant. Thus composition depth adds no new induction law. The premises for each primitive remain.

Command: `work/lean-4.36.0-darwin/bin/lean outputs/RelationshipExperiment.lean`  
Exit status: `0`; standard error: empty. Exact standard output, also saved in [relationship-lean-check.txt](relationship-lean-check.txt):

```text
'RelationshipExperiment.associative' does not depend on any axioms
'RelationshipExperiment.composition_congruent' does not depend on any axioms
'RelationshipExperiment.conditions_compose_as_conjunction' does not depend on any axioms
'RelationshipExperiment.preserves_chain' depends on axioms: [propext]
'RelationshipExperiment.observation_not_congruent_under_continuation' depends on axioms: [propext, Quot.sound]
'RelationshipExperiment.two_implementations_refine_same_relation' depends on axioms: [propext, Quot.sound]
```

Lean version: `4.36.0`, x86_64 Apple Darwin, release commit `611c117bfaf7b7ae1cfcf246ce6fba31e8f509e9`. The local release archive matched SHA-256 `476f9dcf7bee6a070e39a6b15cab7ada48b0086bd91d6e61aa1a454d3da409ce`. `propext` and `Quot.sound` are standard Lean axioms. The file has no `sorry`, `admit`, or custom axiom. Function extensionality was not needed because equality is expressed as `RelEq`.

### Counterexamples

1. **Immediate observation is too weak.** `setHiddenTrue` and `setHiddenFalse` have the same visible output for every input. Composing each with `revealHidden` makes their outputs differ. Lean proves both premises and the failure of congruence. Future use can expose a difference that a current projection hides. A sound replacement rule needs full relational equivalence, a suitable bisimulation, or a proven contextual equivalence for the permitted continuations.
2. **Allowed is not performed.** Both `chooseTrue` and `chooseFalse` refine `allowed := True`, but they have different visible answers. Lean proves this. A broad relation is a specification of possibilities; it does not prove that a particular effect happened, or that two implementations match.
3. **The earlier short-circuit fusion is unsafe.** The [earlier Lean model](CrystalExperiment.lean) mechanically shows loss of an effect before refusal, outcome reclassification, and reordered effects under particular fusions. These remain relevant if Relationship is lowered to executable operations.

## Recovered Hecks inventory and reduction matrix

The normative source is `docs/semantics/bluebook-semantics.md` at local commit `8a8a2699961a00c54fa6858fa5d7d52bd47d084d`. It defines ten numbered semantic sections (§1–§10), a **17-stage** aggregate dispatch order, a closed **28-op** rule AST, three dispatch outcomes, and 52 frozen semantics fixtures. Those numbers count different things; none is an irreducible-construct count. The corpus explicitly excludes persistence mechanics except for the all-or-nothing commit law C8.4, which it says needs separate fault-injecting store tests.

In the table, “representation” means a mathematical encoding is plausible; it does not mean the behavior is implemented or corpus-equivalent.

| Existing concern | Relationship construction | Preserved distinction / remaining obligation | Status |
|---|---|---|---|
| Conditions and predicates | Subidentity relation `a = b ∧ P a` | Decidable evaluation requires a rule language and evaluator. | **Proved embedding** |
| Identity and continuity | Identity relation | Persistent identity across edits needs a chosen key policy. | **Proved law** |
| State and structure | Typed configuration carrier; graph of nodes and edges | Carrier, schemas, and identity do not emerge from composition alone. | Proposed |
| Commands and queries | State transition relation; state-to-answer graph | Keep answer channel and command effects distinct. | Query graph proved; parity open |
| Validation and invariants | Restrict allowed pairs; preservation predicate | Each primitive must prove preservation; refusal precedence matters. | Induction proved; primitive cases open |
| Events and reactions | Labeled relation over state, ordered trace, outbox rows | Trigger commits before reactions; sibling order and status observable. | Proposed; prior runtime probes |
| Policies and sagas | Event-conditioned relations and saga-state transitions | Event/state leg selection, depth bound, compensation order. | Proposed |
| Authority and authorization | Relation indexed by actor, capability, World | No authority can be invented or crossed by composition. | Unproved |
| Ports and adapters | Typed boundary relation | Effect request, execution, reply, and failure are different facts. | Proposed |
| Commit and transaction | Atomic relation on durable state plus events | Isolation, crash points, durability and real-store refinement. | **Unproved**; C8.4 outside corpus |
| Refusal, fault, compensation | Tagged outcomes and transition histories | Three dispatch outcomes, separate reaction failures; compensation is a new action. | Proposed; prior fusion counterexamples |
| Time and causality | Clock in environment; causal labels/partial order | Timing, retries, ordering and fairness need explicit semantics. | Proposed |
| Concurrency and synchronization | Interleaving/partial-order relation or Petri marking | Isolation and synchronization rules cannot be inferred from plain composition. | Unproved |
| External effects | Request and acknowledgement labels | Exactly-once effects do not follow from a relation; idempotency key and adapter contract needed. | Unproved |
| Worlds and inter-World links | Span/cospan or protocol relation over sovereign endpoints | Consent, identities, withdrawal, eventual failure. | Proposed |
| Projection and manifestation | Relation from World configuration to view/action availability | Different Prisms may reveal different observations; preserve permissions. | Proposed |
| Evolution of relations | Versioned rule graph plus migration relation | Existing records, version compatibility, rollout and rollback. | Proposed |
| Successful non-action | Identity transition tagged accepted, empty effect trace | Must differ from refused and skipped reactions. | Expressible; parity open |
| Resource consumption | Linear capability or token transition | Prevent duplicate use and prove durable consumption. | Proposed |

This inventory is recovered from the normative Bluebook sections and the observed runtime probes, not a full count of every DSL form, interpreter branch, or product pattern. “Constraint governing a relationship” is a higher-order predicate on relations; “composition as a relationship between relationships” can be encoded, but doing so still needs typed relation values and a rule for composition. “Nodes are provisional” can mean graph rewrites preserve behavior under a specified observation relation; it does **not** imply that node identity can be discarded when Hecks exposes it.

## Ancestral corpus check

[semantics_corpus_probe.rb](semantics_corpus_probe.rb) replays the 52 JSON fixtures from the local checkout through `Hecks::Fuzzing::Replay`. That helper copies each domain into a fresh temporary directory, binds its store to Memory, and substitutes outside-world adapters. The probe compares refusal kinds, final instances, ordered events with environmental `occurred_at` removed, plus cross-domain and saga fields where the fixture freezes them. It exits nonzero on a mismatch. Exact output in [semantics-corpus.json](semantics-corpus.json):

```json
{
  "source_commit": "8a8a2699961a00c54fa6858fa5d7d52bd47d084d",
  "fixture_count": 52,
  "exact_matches": 52,
  "mismatches": []
}
```

The repository's RSpec version of the same Ruby cases reported `52 examples, 0 failures`, but its process-tree check failed outside the examples because this environment denied `ps`, and its example-status file could not be written in the read-only checkout. That run exited `1`; [full output](semantics-corpus-ruby-rspec.txt) is retained. The independent replay above exited `0`. Neither run is a reduced-algebra differential test. Prior isolated probes in the [earlier report](verification-report.md) exercise Pizza/Pipeline commands, query answers, SQLite outbox interruptions, fanout, and reaction classification; they cover behavior outside these 52 fixtures but are still samples.

## Counts, complexity, and next experiment

| Count | Before | After this experiment |
|---|---:|---:|
| Normative Bluebook semantic sections | 10 | 10 obligations still to preserve |
| Aggregate dispatch stages | 17 | No executable lowering verified |
| Rule AST operators | 28 | No operator reduction verified |
| Frozen semantics fixtures | 52 | 52 baseline matches; **0** relationship-model conformance runs |
| Candidate core relation type | Condition + Relationship hypothesis | 1 denotational type; **not** 1 demonstrated implementation primitive |

The construction removes a separate **mathematical predicate constructor**: `condition P` is a relation. It relocates no verified runtime complexity yet. An unrestricted relation argument can conceal all 17 dispatch stages, 28 operators, persistence, scheduling, and adapters; counting that as one implementation construct would be bookkeeping, not reduction. The carrier, tags, trace, interpreter, store, and adapter contracts remain explicit proof obligations. No measured CI reduction follows. The inductive theorem removes proof repetition caused solely by sequence depth; primitive semantics, independent concurrency cases, and fusion equivalences still need checks.

**Recommended next experiment:** define a finite, inspectable relationship grammar with no arbitrary callbacks. Give it a labeled configuration containing command/answer, accepted/refused/faulted status, ordered trace, durable state, outbox rows, actor authority, and clock. Translate one frozen fixture from each of Bluebook §§1–10 into that grammar, then mechanize a small-step interpreter and compare its observations with the frozen `expect`. Start with accepted and refused Pizza, query answer, committed trigger with refused reaction, and an injected torn-write attempt. Prove the interpreter refines the relation and that composition preserves an authority boundary; add a contextual or bisimulation rule before any fusion. Only then expand toward all 52 fixtures and the outbox/concurrency corpus.

## Evidence status

- **Proven in Lean:** relation identity, associativity, full-relation congruence, condition embedding/conjunction, query graph uniqueness, finite-chain invariant preservation under per-step premises, and both counterexamples.
- **Empirically demonstrated:** ancestral Ruby runtime matches all 52 frozen semantics fixtures in isolated replay; earlier probes establish specific Pizza, Pipeline, outbox, and reaction behaviors.
- **Hypothesized:** a constrained relationship grammar can express every consequential Hecks behavior and World interface without opaque primitives.
- **Disproven:** immediate visible-output equivalence is sufficient for arbitrary later composition; a permissive relation guarantees a chosen implementation's visible result.

No push, tag, release, or publication occurred. The ancestral checkout remained clean.
