# Crystal Era: the 20 executable forms under corpus pressure

**Later result:** The function/expression follow-up reached 32/52 exact matches with 16 instruction and 12 expression forms. See the [latest audit and verdict](function-expression-conformance.md). The counts below describe the earlier corpus pass.

## Result

The original “20” counted **11 tested instruction forms and nine tested expression forms** in the first Pizza/Meter slice. It was a vocabulary count, not 20 irreducible constructs. Extending the independent interpreter against the frozen semantics corpus required three more instructions (`numeric`, `ensures`, `remove`) and two more expressions (`add`, `str`). The current tested vocabulary is therefore **14 instructions plus 11 expressions = 25 forms**. This increase is evidence that the initial slice omitted behavior, not evidence against the single-relation mathematical model.

The ancestral Hecks runtime matched **52/52** frozen fixtures in isolated replay. The independent interpreter now matches **19/52** exactly; **30** stop at unsupported behavior and **3** produce wrong observable results. These statuses are deliberately distinct. The full machine-readable [audit](full-corpus-audit.json) names every fixture and its first observed blocker. Source for the [isolated audit](full_corpus_audit.rb), [compiler/interpreter](ir_relationship_core.rb), and [regression probe](ir_relationship_probe.rb) is included.

## Classification of the original 20

“Semantic” means changing or rejecting a state transition is observable. “Evaluation” means the form supplies a rule's value or truth. “Determination” means it chooses among allowed answers. “Boundary” means it calls for a physical action. A form can play more than one role; the table gives its principal role and the conformance obligation that remains.

| Form | Principal role | What a transparent reduction would have to preserve |
|---|---|---|
| `required` | Semantic refusal | Argument presence, refusal kind, and first-failure order. A generic check can encode it only with those details. |
| `validate` | Semantic refusal/evaluation | Type, value-object pattern, nested field, null, and numeric range rules; error precedence. |
| `from` | Semantic lifecycle guard | Allowed source states, absence handling, and lifecycle refusal order. |
| `given` | Semantic condition | Predicate evaluation scope and first unmet guard. Mathematically a subidentity relation. |
| `set` | Semantic state effect | Field assignment and pre-command reads of effect sources. |
| `append` | Semantic state effect | List order, field construction, and event/state rollback on refusal. |
| `transition` | Semantic state effect | Lifecycle destination, source guard, and transition order. May lower to guard plus assignment if the observable order survives. |
| `event` | Semantic observation | Payload and emission order; rejected commands emit nothing. |
| `commit` | Physical boundary | Atomic state/event/outbox persistence. A relational contract describes it but does not perform it. |
| `where_lt` | Semantic query evaluation | Typed argument, comparison, and answer membership. Could share a comparison rule with command guards. |
| `order` | Determination | Observable row order, including ties, nulls, and string/numeric comparison. |
| `lookup` | Evaluation/scope | Argument-first guard lookup versus state-first settled-state lookup, plus `old` pre-state references. |
| `size` | Evaluation | Collection length and string-length conventions for every admitted value type. |
| `int` | Literal data | Integer literal value and range. This is syntax/data, not a separate state transition. |
| `compare` | Evaluation | Mixed numeric comparison, string ordering, null behavior, and faults. |
| `sign_test` | Evaluation shorthand | May lower to comparison with zero where types and fault behavior agree; that equivalence is not proved across the corpus. |
| `not` | Evaluation | Boolean negation and its input type/fault behavior. |
| `empty` | Evaluation shorthand | May lower to `size = 0` for supported strings/lists only after checking null and type behavior. |
| `to_s` | Evaluation/coercion | Exact scalar formatting and errors. It cannot be erased by calling it a relation. |
| `strip` | Evaluation | Exact whitespace semantics and validation order. |

The five forms added under corpus pressure are `numeric` (increment, decrement, multiply, clamp, operand typing and overflow), `ensures` (postcondition on the settled candidate with access to `old`), `remove` (all structural matches), `add` (integer/float expression arithmetic and faults), and `str` (string literal data). Their implementation is a tested subset of Hecks behavior; the table does not claim a full translation.

## Conformance audit

The audit reads each frozen fixture from ancestral commit `8a8a2699961a00c54fa6858fa5d7d52bd47d084d`. It boots a copied domain in an isolated temporary directory, compiles its parsed Bluebook, executes the fixture steps in the independent interpreter, and compares the expected `instances`, `events`, and `refusals` exactly. It does not mutate the ancestral checkout. Fixtures requiring additional expected outputs are currently marked unsupported. The audit records the **first** blocker reached, so a blocked fixture may have further untested behavior.

| Status | Count | Interpretation |
|---|---:|---|
| Exact match | 19 | All compared instance, event, and refusal data equal the frozen oracle. |
| Unsupported | 30 | The interpreter or audit cannot run the fixture through to comparison. No conformance claim. |
| Mismatch | 3 | It ran and gave an observably wrong result. |

The 30 first blockers are: 19 `Reference<Customer>` value-object cases; three cross-domain expected outputs; two saga expected outputs; and one each for `TrueClass` validation, literal source, ad hoc query, nil equality, structured append fields, and a transition source mismatch. The three wrong results are `policy_with_reads_emitter_id`, `reaction_depth_bound`, and `reaction_order_per_event`: the independent interpreter omits the policy/reaction effects that add expected instances or events. These are genuine gaps, not parser-only failures.

The prior Pizza/Meter regression still passes: eight Pizza fixtures, the separate Pizza query answer, the Meter fixture, sold-state refusals, and two-pizza ordering. The Meter probe also confirms that a sequential-candidate read would yield the wrong prior value. See the exact [regression output](second-domain-results.json). Syntax checks returned `Syntax OK` for the audit and interpreter; both stderr files are empty. The ancestral checkout remains clean.

## What to prove or implement next

1. Generalize reference values and dereference semantics, then rerun all 52. The 19 blocked reference fixtures are the largest cluster, but their later outcomes are unknown.
2. Implement policy and reaction scheduling with observable event order, depth, refusal, and rollback rules. The three present mismatches provide concrete differential tests.
3. Extend the oracle comparison to cross-domain and saga outputs, query answers, and the remaining special step shapes. A fixture excluded by the harness is not a pass.
4. Only after full corpus conformance, attempt reductions such as `sign_test → compare` or `empty → size`, with mechanical preservation proofs and differential tests for fault/refusal precedence.

The existing Lean proofs establish relation laws, finite-table limits, and selected boundaries. They do **not** certify this Ruby compiler, this interpreter, all 28 ancestral rule-AST operators, all 17 dispatch stages, or physical adapter implementations. Full corpus conformance would be stronger empirical evidence, but would still not by itself prove those implementations correct. No push, tag, release, or publication occurred.
