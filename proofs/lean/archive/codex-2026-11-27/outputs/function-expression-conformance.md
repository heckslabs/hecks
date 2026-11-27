# Crystal Era: testing the function/expression split

**Later result:** The [authorization, projection, and reaction follow-up](executable-boundaries-verdict.md) reached 37/52 exact matches and five new focused regressions. The counts below describe the earlier pass.

## Finding

The split survived a useful next slice, but it is **not yet established for full Hecks**. An inspectable command expression can carry a reference declaration and a rule such as `customer.status == "active"`. A generic evaluator can resolve the customer ID to a record before evaluating that rule. This made the ancestral `reference_argument_dereferenced` fixture match exactly, without an opaque callback in the expression.

Extending the independent interpreter from the prior 19 matches to the current **32/52 exact matches** required explicit mechanisms for reference resolution, declared defaults, projections on creation, typed append fields and literals, entity identity minting, entity invariants, compound aggregate identities, and unknown-argument precedence. The vocabulary now contains **16 instruction forms and 12 expression forms**, up from the initial 11 plus nine. This is a count of tested syntax forms, not irreducible constructs. The [exact audit JSON](function-expression-audit.json) records every fixture. The [current interpreter](ir_relationship_core.rb), [audit runner](full_corpus_audit.rb), [regression probe](function_expression_regression_probe.rb), and [regression output](function-expression-regression.json) make the result reproducible.

| Outcome | Fixtures | Meaning |
|---|---:|---|
| Exact match | 32 | Instances, events, and refusals equal the frozen oracle. |
| Unsupported | 15 | The audit or interpreter stopped before a complete comparison. |
| Mismatch | 5 | It ran, but the observable result differs. |

The ancestral Ruby runtime's isolated baseline remains 52/52. The current independent interpreter's Pizza/Meter regression still matches its eight Pizza fixtures, one Meter fixture, separate Pizza query answer, sold-state refusals, and two-pizza query ordering. Both Ruby syntax checks returned `Syntax OK`; audit and regression stderr are empty. The ancestral checkout is clean.

## What the split means operationally

| Layer | Inspectable data | Generic function required |
|---|---|---|
| Admissibility | Guards, types, lifecycle states, postconditions, invariants | Evaluate expressions with declared scopes and failure order. |
| Determination | Command order, query order, reaction/policy declarations | Choose one result and schedule dependent steps deterministically. |
| Realization | State changes and ordered event intents | Commit atomically and perform port effects under an explicit contract. |

The reference fixture is a concrete positive test: `Reference<Customer>` and the guard remain visible as data; the evaluator performs a repository lookup and supplies a scoped value. The ID and target record are still distinct, and a missing record must yield a declared `NotFound` result. A function that can call arbitrary domain code would make the test vacuous. This interpreter uses explicit cases over inspected IR, not such a callback.

The added cases also reveal the cost of the split. The evaluator must be more than a simple function application: it needs type-directed value construction, identity rules, ordering, scope rules, and transaction semantics. The current Ruby implementation still contains special-case assumptions and incomplete dispatch ordering, so it is **not** a proven small universal evaluator.

## Remaining corpus boundary

Five fixtures run but disagree:

| Fixture | Missing or incorrect behavior indicated by the comparison |
|---|---|
| `environment_caller_role` | Caller authorization must precede the attempted create; current interpreter reports `AlreadyExists`. |
| `given_first_failure_wins` | A projection refresh and resulting reaction/event must occur after customer suspension; current state remains stale. |
| `policy_with_reads_emitter_id` | Policy-driven command and event are absent. |
| `reaction_depth_bound` | Reaction chain/depth behavior is absent. |
| `reaction_order_per_event` | Ordered per-event reactions are absent. |

The 15 unsupported fixtures include three cross-domain output shapes and two saga output shapes excluded by the present audit, plus correction, delegation, entity command, ad hoc query, nil equality, reaction, and projection paths. “Unsupported” means untested, not conformant. The audit records the first blocker only; fixing one may reveal a later mismatch.

## Verdict and next test

**Provisional yes to a function/expression architecture; no claim of full executable reduction.** The decisive test is to reach 52/52 with all behavior expressed in a closed, inspectable language, then prove the evaluator's preservation laws and its correspondence to the physical adapter contracts. The next high-value target is reaction and policy scheduling, because three current mismatches directly expose it. Projection refresh and authorization follow. A full corpus pass would be empirical conformance, not a mechanical proof of the Ruby compiler or transactional store.

The earlier Lean proofs cover relational composition, invariant preservation, finite-table limits, and selected boundary laws. No new Lean theorem certifies this expanded interpreter. No push, tag, release, or publication occurred.
