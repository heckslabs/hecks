# Crystal Era executable reduction: frozen corpus conformance

## Result

At ancestral Hecks commit `8a8a2699961a00c54fa6858fa5d7d52bd47d084d`, the independent in-memory Relationship interpreter matched **all 52/52 frozen semantic fixtures**. It also matched the five targeted authorization, projection, and reaction fixtures. The ancestral checkout remained clean; no push, tag, release, or publication occurred.

This is **demonstrated conformance on a finite corpus**, not a proof that one universal evaluator can implement every Hecks behavior.

## Last two counterexamples and corrections

| Fixture | Smallest relevant trace | Incorrect reduced result | Boundary and correction | Result |
|---|---|---|---|---|
| `reaction_depth_bound_compensation` | Install lamp; light it; repeated flickers reach reaction depth 5. | Saga dispatches were skipped without an advance, refusal record, compensation attempt, or unwind log. | Depth is execution context, while the leg, dispatch, compensation, and unwind are declared saga relationships. The runner now advances the leg at the ceiling, records the blocked dispatch, unwinds, drains compensation newest first, and records refused-handler dispatches and later state mismatches. | **Demonstrated exact** state, events, refusals, and 14 saga log rows. |
| `reaction_depth_four_compensation_runs` | Lay fuse; arm it; strike causes a four-step reaction chain ending in `Burnt`. | `Fuse.Blow` raised an internal transition mismatch; the completed `Prime` compensation and `Scrap` were absent. | An invalid lifecycle source is a domain refusal. The runner converts it to `LifecycleRefused`, records the failed saga dispatch, then runs `Unprime` and `Scrap` at the allowed fifth reaction level. | **Demonstrated exact** state, events, refusals, and 9 saga log rows. |

The implementation is in [the interpreter](ir_relationship_core.rb) and [reaction runner](relationship_reactions.rb). The [full audit](full-corpus-final-audit.json) compares each fixture's declared observations exactly. For all 52 fixtures those include state, events, and refusals; the three cross-domain cases additionally compare cross-domain records, and the two compensation cases compare saga logs.

## Exact checks

```text
full frozen corpus:        {"match":52}
five boundary regressions: {"match":5}
Ruby syntax:               Syntax OK (interpreter, reaction runner, audit)
ancestral checkout:        clean
```

The exact machine-readable outputs are [full corpus](full-corpus-final-audit.json), [boundary regressions](final-boundary-regressions-audit.json), and [Pizza/Meter regression](final-pizza-meter-regression.json). The latter reports all sampled matches true, including two sold-state refusals and the Meter case; it deliberately reports `sequential_candidate_read_matched: false`, the previously known unsafe sequential candidate. Both regression runs exited `0` with empty standard error.

## Status by claim

- **Proven:** Earlier Lean proofs establish abstract composition, invariant, and observational laws under their stated assumptions. No new proof connects this Ruby interpreter to ancestral Hecks.
- **Demonstrated:** The interpreter reproduces every declared observation in the 52 frozen fixtures, including the specific authorization, projection, policy, saga, cross-domain, delegation, query, and compensation cases in that corpus.
- **Hypothesized:** These behaviors can be represented through inspectable Relationship declarations plus a specialized execution substrate, without another domain semantic constructor. The saga ledger and reaction depth are explicit execution state; their scheduling remains consequential.
- **Unresolved:** Coverage outside the frozen fixtures; durable outbox delivery, claims, retries, concurrency, restarts, adapter failures, authorization providers, and full trace equivalence. Most fixtures do not declare query answers, policy logs, outbox rows, or saga logs as expected outputs. The compiler still reads ancestral Bluebook IR, so this is not an independent parser or source-language proof. Nothing here establishes an instruction-count reduction or universal evaluator sufficiency.

The next meaningful gate is to widen the oracle to internal execution observations and failure schedules, then prove or refute refinement of the in-memory interpreter to durable realization. Instruction-count optimization should wait for that gate.
