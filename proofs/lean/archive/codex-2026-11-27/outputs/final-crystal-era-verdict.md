# Crystal Era formal experiment: final verdict

## Answer

**Relationship is a defensible single denotational core. It is not yet a demonstrated single executable construct for Hecks.** Lean mechanically verifies that a Condition can be a subidentity relation, that relations compose associatively with identity, that full relational equivalence is a congruence, and that per-step invariant preservation carries through arbitrary finite composition. A finite interpreter's execution also equals the composition of its graph relations. These results are mathematical facts about the stated models.

The reduction was tested against ancestral Hecks commit `8a8a2699961a00c54fa6858fa5d7d52bd47d084d` in isolation. The ancestral Ruby runtime matched all **52/52** frozen semantics fixtures. A source-derived, independent interpreter matched **8/8 Pizza fixtures**, including a query answer checked separately against Hecks, plus **1/1 Meter fixture** from a second domain. Targeted tests also matched sold-state lifecycle refusals, a two-pizza query order, committed trigger/refused reaction, an injected SQLite rollback, and a caller-role boundary. These are slices, not full-corpus conformance of the reduced interpreter.

The strongest falsification in this final transfer test is **Meter's pre-state rule**. The same IR compiler lowered `Install` and `Read` without a Meter-specific interpreter branch. `Read` declares a write to `current` *before* a write to `previous` sourced from `state(:current)`. The correct model evaluates every source against the pre-command state and reaches `current=9, previous=5`, exactly matching the frozen fixture. An otherwise identical sequential candidate-reading variant reaches `previous=9` and fails. This distinction cannot be erased by calling both updates “relationships.”

## Exact final proof-checker output

[PreStateEffects.lean](PreStateEffects.lean) defines finite assignment data, a pre-state evaluator, graph relations for each assignment, and their relational composition. `run_realizes_relation` proves that the interpreter agrees with that composition for every finite list. The two concrete Meter theorems check the correct result and the unsafe alternative.

Command: `LEAN_PATH=work work/lean-4.36.0-darwin/bin/lean outputs/PreStateEffects.lean`  
Exit status: `0`; standard error: empty. Exact standard output in [pre-state-lean-check.txt](pre-state-lean-check.txt):

```text
'PreStateEffects.run_realizes_relation' depends on axioms: [propext]
'PreStateEffects.meter_reads_pre_state' does not depend on any axioms
'PreStateEffects.sequential_candidate_read_is_wrong' does not depend on any axioms
```

`propext` is a standard Lean axiom. There is no `sorry`, `admit`, or custom axiom. Earlier exact checks and assumptions are in the [relationship report](relationship-reduction-report.md), [commit/reaction report](executable-relationship-report.md), and [authority report](authority-relationship-report.md). No Lean theorem proves the Ruby compiler correct or a physical adapter atomic.

## Exact transfer result

The [IR compiler and interpreter](ir_relationship_probe.rb) read the ancestral Bluebook `to_h` IR and execute finite instruction data independently of Hecks dispatch. The [compiled Meter programs](compiled-meter-programs.json) contain five instructions for `Install` and six for `Read`. Command: `HECKS_SOURCE=/Users/christopheryoung/Projects/hecks PROGRAM_DUMP=outputs/compiled-pizza-programs.json METER_PROGRAM_DUMP=outputs/compiled-meter-programs.json ruby -I/Users/christopheryoung/Projects/hecks/lib outputs/ir_relationship_probe.rb`. Exit status: `0`; standard error: empty. The decisive section of [exact output](second-domain-results.json) is:

```json
"meter_second_domain": {
  "matched": true,
  "compiled_instruction_counts": {"Install": 5, "Read": 6},
  "current": {"value": 9},
  "previous": {"value": 5},
  "sequential_candidate_read_matched": false,
  "sequential_candidate_previous": {"value": 9}
}
```

All eight Pizza fixture rows remain `matched: true` in the same run. The query comparison uses a separate isolated Hecks replay because the frozen fixture does not include the successful answer. The Meter comparison uses the frozen `effects_read_the_pre_state.json` expectation. The runner handles only its declared subset; unsupported IR shapes raise rather than silently invoking Hecks.

## Construct and complexity accounting

| Layer | What the experiment established | Count and interpretation |
|---|---|---|
| Denotation | A condition and a transformation can both be represented by `Rel A B`; query answers can be relation codomains. | **1 relation type**, if arbitrary relations are permitted. |
| Checked finite core | Execution agrees with composed graph relations; pre-state rule, atomic model boundary, reaction status, and authorization wrapper have scoped theorems. | Several explicit instruction types and state fields; no minimality proof. |
| IR-derived executable slice | Pizza and Meter programs use `required`, `validate`, `from`, `given`, `set`, `append`, `transition`, `event`, `commit`, `where_lt`, `order`. | **11 instruction tags** plus nine supported rule-AST tags and value validation; not a one-operation runtime. |
| Ancestral Hecks obligations | Normative Bluebook has 17 aggregate dispatch stages and a closed 28-op rule AST; 52 frozen semantics fixtures establish a baseline. | Different units from instruction tags; no defensible numerical “17/28 to 11” reduction claim. |
| Physical substrate | SQLite transaction, outbox claim/delivery, actor binding, and external effects require operational contracts. | Complexity specified and tested in slices, not mathematically eliminated. |

An unrestricted `A → B → Prop` can encode any implementation's behavior, so its single name alone does not establish architectural minimality. The finite grammar keeps the consequential rules visible. In particular, failure versus refusal, accepted trigger versus reaction refusal, pre-state versus intermediate-state reads, authority enforcement, and atomic versus torn commit remain distinct observations. The prior claim that CI might need fewer than ten checks, or two checks, is **not** supported by these experiments. Composition depth admits one inductive proof rule, but each primitive, observation boundary, physical adapter, and proposed fusion still has a proof obligation.

## Status

- **Proven:** the stated Lean algebraic laws, model interpreter/relationship correspondence, model atomic/refusal and authority properties under their premises, and the pre-state Meter counterexample.
- **Empirically demonstrated:** 52/52 ancestral baseline; 8/8 Pizza and 1/1 Meter fixture matches for the independent IR-derived subset; targeted query, lifecycle, reaction, SQLite fault, and role probes.
- **Disproven:** immediate observation equivalence is always safe under future composition; a permissive relation guarantees a chosen implementation's result; sequential candidate-reading effects preserve Meter semantics.
- **Unproven:** one non-opaque executable primitive, complete Hecks corpus translation, compiler refinement into Lean, concurrent isolation, full authorization parity, external delivery guarantees, and a CI check-count reduction.

**Recommendation:** retain Relationship as the semantic language for further work, with finite typed instruction data and explicit substrate contracts. Do not collapse executable operations or CI gates based on the current one-type theorem. The next decision should be made from a full compiler-correctness and corpus-conformance proof, rather than a constructor count.

All work stayed local. The ancestral checkout remained clean. No push, tag, release, or publication occurred.
