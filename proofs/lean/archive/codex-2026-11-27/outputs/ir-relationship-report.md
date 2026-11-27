# Bluebook IR to Relationship experiment

## Result

The next lowering step reads the **actual ancestral Pizza Bluebook IR**, compiles three commands and one named query into finite instruction data, and executes those instructions with an independent interpreter. It matches **all eight frozen Pizza semantics fixtures** on ordered refusals, final instances, and ordered events. For the query fixture it also matches the successful query answer obtained from an isolated Hecks replay. Additional tests match Hecks on two-pizza filtering/order and on attempts to purchase or add a topping after the pizza is sold. This is a larger, source-derived slice than the earlier two handwritten Pizza programs, but it is still not a complete Hecks implementation.

The source-derived check exposed an error in the earlier handwritten example: that example omitted the ten-topping limit, required-argument precedence, the positive-payment rule, lifecycle gating, and value-object validation. Its two matches were correct for those inputs but did **not** establish full semantics for its three commands. The IR-derived compiler includes those rules that its checked fixtures exercise. No earlier result should be read as full command parity.

## What was compiled

[ir_relationship_probe.rb](ir_relationship_probe.rb) boots the local ancestral domain to obtain its public `to_h` IR. It reads command attributes, `from`, ordered given ASTs, mutations, lifecycle transitions, emits, aggregate defaults, and one query's filter and ordering. It lowers `CreatePizza`, `AddTopping`, `Purchase`, and `CostingLessThan` to [reviewable instruction data](compiled-pizza-programs.json). Execution then uses the probe's own evaluator; it never calls Hecks dispatch for the reduced run. It does call isolated Hecks replay to obtain the independent query-answer oracle. Unknown mutation or AST tags raise rather than falling through to the Hecks runtime.

| Command | Compiled instructions |
|---|---:|
| CreatePizza | 7 |
| AddTopping | 8 |
| Purchase | 11 |
| CostingLessThan | 3 |

There are **eleven instruction tags** across those programs: `required`, `validate`, `from`, `given`, `set`, `append`, `transition`, `event`, `commit`, `where_lt`, and `order`. The expression evaluator supports the nine AST tags actually needed here: `lookup`, `size`, `int`, `compare`, `sign_test`, `not`, `empty`, `to_s`, and `strip`. Value validation additionally interprets nested value objects, scalar types, regex patterns, and invariants. These tags and routines are real executable complexity; naming the whole interpreter a Relationship does not remove them.

The `to_h` IR and rule ASTs are produced by Hecks's existing parser and builder. This experiment therefore inherits that parser as an input dependency. It does not demonstrate that the parser itself can be reduced.

## Exact comparison

Command: `HECKS_SOURCE=/Users/christopheryoung/Projects/hecks PROGRAM_DUMP=outputs/compiled-pizza-programs.json ruby -I/Users/christopheryoung/Projects/hecks/lib outputs/ir_relationship_probe.rb`  
Exit status: `0`; standard error: empty. [Exact JSON output](ir-relationship-results.json) reports all eight matches:

```text
accepted_pizza_lifecycle                  matched
given_unmet_leaves_the_record_purchasable matched
collection_guard_toppings                 matched
absent_argument_refused                   matched
vo_pattern_before_invariant               matched
string_field_refuses_other_scalars        matched
vo_field_null_refused                     matched
query_argument_typed                      matched
```

The earlier isolated ancestral corpus replay matched all 52 fixtures against their frozen expectations. Here the compiled interpreter is compared with the same `expect` objects, not merely with a live runtime result. The eight fixtures cover successful create/append/purchase, guard order, the eleventh-topping refusal, absent-argument wording, string type mismatch, null nested fields, pattern refusal before a value-object invariant, and query argument validation. These are exact matches for the listed input sequences only.

`query_argument_typed` requires named-query argument validation and a query answer. The semantics corpus freezes its refusal and state/events but not the successful answer, so the probe separately compares both query entries against `Hecks::Fuzzing::Replay`: the negative ceiling refuses with `InvariantViolation`, and the ceiling of 3000 returns the `everything` row. A second, synthetic sequence creates `zeta` at 1200 and `alpha` at 800; ceilings of 1000 and 2000 return IDs `[alpha]` and `[alpha, zeta]`, respectively, matching Hecks. This tests one comparator and ascending name order, not the full query language.

Two more synthetic sequences reuse the accepted Pizza lifecycle fixture and then attempt `Purchase` or `AddTopping` after the pizza is sold. Both produce Hecks's `LifecycleRefused` outcome, with identical final state and event history. The exact Boolean comparison results are recorded under `sold_state_refusal_matches` in the JSON output. These are targeted adversarial inputs; they do not cover every lifecycle transition or refusal precedence.

## Formal status and limitations

The [Lean relationship model](RelationshipExperiment.lean) proves composition laws for arbitrary relations. The [finite Lean interpreter](ExecutableRelationship.lean) proves its own execution agrees with the composition of its graph relations. **There is no Lean proof that this Ruby IR compiler or its evaluator refines either Lean model.** This is empirical differential evidence plus separately checked algebra, not a mechanized Hecks compiler correctness theorem.

The subset omits unknown-argument precedence, many value types and AST operators, entity delegation, postconditions, all other query forms, ports, policies, sagas, outbox delivery, authority, concurrency, and physical transaction semantics. Its `from` instruction handles the tested sold-state refusal but has not been checked for every lifecycle shape or step-order conflict. Its `commit` updates in-memory structures and is not the SQLite transaction checked in the separate [boundary experiment](executable-relationship-report.md). These are explicit unsupported or unverified paths.

**Conclusion:** IR-driven lowering is feasible for a consequential slice and catches behavior the handwritten examples missed. The observed executable algebra is currently eleven instruction tags, plus expression and validation machinery. The one-Relationship claim remains a denotational theorem and an architectural hypothesis, not an achieved reduction to one non-opaque executable construct.

**Final transfer update:** the second-domain Meter check was completed afterward using this same compiler. It matches the frozen pre-state effect fixture; a sequential candidate-reading variant fails. See the [final verdict](final-crystal-era-verdict.md) and [exact transfer output](second-domain-results.json). The compiler source linked above now includes that Meter check.

No ancestral source was changed. No push, tag, release, or publication occurred.
