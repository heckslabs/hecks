# Crystal Era: accounting for “one Relationship”

**Latest boundary result:** 37/52 completed frozen fixtures and five focused authorization/projection/reaction regressions match the ancestral observations; 15 corpus fixtures remain unsupported. See the [executable boundary verdict](executable-boundaries-verdict.md). The detailed ledger below predates that follow-up.

## What the count means

The experiment supports **one mathematical relation type**: a Condition is a relation that preserves its input, and a transformation is a relation between configurations. That count is real at the level of denotation. It is **not** a count of executable operations, rule vocabulary, proof obligations, or physical mechanisms.

The strongest one-operation candidate tested was an inspectable finite relation table with a single `fire?` lookup. Lean proved soundness and completeness for functional tables, then proved that every finite table misses some fresh natural-number input. A symbolic rule handles unbounded increment, but it requires expression forms and an evaluator. [Proof attempt and exact output](one-fire-proof-attempt.md).

## Complexity ledger

| Concern | Accounting | Evidence and present status |
|---|---|---|
| Separate Condition type | **Removed in denotation.** A predicate is the subidentity relation `a=b ∧ P(a)`. | Mechanically proved in [relationship model](RelationshipExperiment.lean). Decidable rule evaluation remains. |
| Composition by depth | **Proof repetition removed.** Identity, associativity, congruence, and invariant preservation extend to arbitrary finite chains under per-step premises. | Lean proofs in [relationship model](RelationshipExperiment.lean). Primitive premises remain. |
| Choice among admissible results | **Relocated into determination.** The full relation may allow two outcomes; first-match order, priority, or a deterministic rule selects one. | Lean proves two determinations can refine one admissibility relation and that a renaming-invariant selector for the symmetric Boolean case is impossible. [Exact check](realization-lean-check.txt). |
| Creation of nonidentity behavior | **Requires rule content.** Identity and composition alone never change state. A finite edge table is transparent but cannot express an unbounded successor everywhere. | Lean theorems in [realization boundary](RealizationBoundary.lean) and [one-fire candidate](OneFire.lean). Symbolic expressions repair only the tested increment case. |
| Rule/expression language | **Relocated, not removed.** The initial slice used 11 instruction tags and nine AST tags. The latest corpus audit requires 16 instruction tags and 12 expression tags, plus nested value validation and regex checks. | [Function/expression audit](function-expression-conformance.md) and [compiler source](ir_relationship_core.rb). These counts are from the tested subset, not full Hecks. |
| Dispatch precedence and refusal kinds | **Still semantic.** Which check runs first decides the observable refusal; accepted, refused, and faulted remain distinct. | Pizza subset checks missing args, type/pattern validation, givens and lifecycle. Hecks vocabulary has 17 aggregate stages and 15 named domain refusal classes. Full precedence is unproved. |
| Pre-state effects | **Explicit semantic rule.** Effect sources in one command read the pre-command state even if their targets are written earlier. | Meter fixture matches `current=9, previous=5`; sequential candidate read yields previous `9` and fails. [Lean check](pre-state-lean-check.txt). |
| Queries and observation | **Explicit answer channel.** A query relation goes from configuration to an answer; its result, filter order and validation are observable. | One named Pizza query and a two-pizza ordering probe match Hecks. Other query forms remain untested. |
| Commit and durability | **Specified relationally; physically supplied by store.** State, event, and outbox writes must be atomic. | Isolated SQLite fault probe rolled back after record insert; Lean proves a torn write differs from atomic rollback. This is not a formal verification of SQLite or all adapters. |
| Reactions and delivery | **Separate causal phase.** Trigger acceptance survives a refused reaction; outbox status and order remain visible. | Isolated Hecks and reduced SQLite boundary probes match the sampled refusal/rollback projections. A general reaction/saga compiler is absent. |
| Authority | **Condition plus enforcement boundary.** Capability constraints can be relations, but every entry point must apply them. | Lean wrapper proves arbitrary-length noninterference under its actor=World premise; one Hecks caller-role fixture matches the no-write pattern. Hecks grants and tenant boundaries are not refined. |
| Time, concurrency, outside effects | **Not eliminated.** Clock, scheduling, isolation, retries, idempotency, and port acknowledgements need explicit contracts and observations. | No complete reduced-model differential or mechanical adapter proof. The prior Hecks probes cover selected crash and outbox states only. |
| Worlds, Prisms, evolution | **Still hypotheses.** Relationship notation can describe links, projected views and migration, but identity, permissions, protocol and version compatibility need semantics. | No ancestral conformance test or Lean refinement proof for these features. |

The first two rows are the clearest complexity *removed*. Rows three through ten are mostly complexity *made explicit or moved into data and substrate*. The final rows remain open. A universal `Relationship` callback would make this ledger disappear from sight while leaving the work intact; it is not an acceptable reduction under the stated objective.

## Coverage ledger

| Reference surface | Reduced-model result | Boundary |
|---|---:|---|
| Frozen Bluebook semantics corpus | **32 of 52** fixtures matched by the IR-derived interpreter; 15 stopped at unsupported behavior and five produced wrong results. | The ancestral Ruby baseline matched 52/52 against its oracle. See the [latest audit](function-expression-audit.json); this is not 52/52 reduced conformance. |
| Pizza named query | Query refusal and successful answer matched Hecks; two-pizza filter/order also matched. | One comparator and ascending name order. |
| SQLite commit/reaction | Targeted projections matched Hecks and survived model database reopen. | Not a full physical-store refinement proof. |
| Authority | One caller-role fixture showed unchanged state/events on two wrong-role attempts. | The reduced IR compiler does not enforce Hecks's full authorization system. |
| Lean | Core relation laws, finite interpreter correspondence, scoped commit/reaction/authority laws, pre-state effects, and one-fire candidate theorems checked. | No Lean proof connecting the Ruby IR compiler or all Hecks adapters to the formal models. |

The **17 dispatch stages**, **28 rule-AST operators**, **15 refusal classes**, **16 currently tested instruction tags**, **12 currently tested expression tags**, and **one relation type** count different units. Subtracting one from another would be misleading. The earlier idea that CI could fall below ten checks, or to two checks, has no measured support. Composition depth needs one inductive law; each semantic primitive, adapter contract, compiler lowering, and proposed fusion still needs its own verification.

## Three layers and the residual boundary

1. **Admissibility:** what may happen — a relation.
2. **Determination:** what is selected — also a relation, narrower than admissibility, with a declared choice policy or functional rule.
3. **Realization:** what happened — an observed, causally performed transition. Its contract can be relational, but a return value or proof term does not itself durably write or deliver.

The smallest remaining piece that cannot be *obtained merely from relation truth* is **realization of a selected transition**. It may be a generic physical substrate rather than a second domain-level semantic construct. The kernel-dissolution hypothesis survives only in this precise form: domain rules could become manifested, inspectable relationship data, while a small generic evaluator and transactional/port boundary remain explicit and proven against them. The experiment has not proved that this residual boundary can cover all Hecks behavior.

No ancestral source was changed. No push, tag, release, or publication occurred.
