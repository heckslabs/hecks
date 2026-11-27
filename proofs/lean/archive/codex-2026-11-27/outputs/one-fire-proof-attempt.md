# Attempt to prove one transparent executable construct

## Claim tested

I tested an explicit candidate rather than treating `Relationship` as an arbitrary callback: a finite table of configuration pairs, with one executable operation, `fire?`, that scans for the first pair whose source matches the current configuration. A configuration can include state, outcome, trace, outbox, and authority fields; the theorem is polymorphic in its type. The table is inspectable data and the lookup algorithm is fully visible.

**Result:** this one-operation candidate has a soundness proof and a conditional completeness proof, but it **cannot** implement the unbounded behavior Hecks requires. A symbolic rule repairs that particular limitation, yet brings an expression grammar and evaluator back into view. This is a failed proof of the full one-operation Hecks claim, not an impossibility proof for every conceivable one-operation design.

## Mechanical results

[OneFire.lean](OneFire.lean) proves:

1. **Soundness:** whenever `fire? table s = some t`, the pair `(s,t)` is declared in the table.
2. **Completeness under determination:** if the table is functional (at most one output for each input), `(s,t)` is declared exactly when `fire? table s = some t`.
3. **Nondeterministic selection is an extra rule:** with both `(0,1)` and `(0,2)` declared, first-match `fire?` selects `1`, not `2`. The table's order determines the result.
4. **Finite-table obstruction:** for any finite table over natural-number states, there is a fresh input greater than every listed source where `fire?` returns `none`. Therefore no such table implements `s ↦ s+1` for all natural numbers. The source claim is relevant to Hecks because identities and counters are not bounded to a compiled finite list.
5. **Symbolic repair:** one rule containing a finite expression tree `input + 1` executes increment for every natural number, and its `symbolicFire` result is exactly its declared relation. This uses no arbitrary callback. It exposes three expression forms (`input`, `literal`, `plus`) and their evaluator as remaining executable machinery.

Command: `work/lean-4.36.0-darwin/bin/lean outputs/OneFire.lean`  
Exit status: `0`; standard error: empty. Exact standard output in [one-fire-lean-check.txt](one-fire-lean-check.txt):

```text
'OneFire.fire_sound' depends on axioms: [propext]
'OneFire.fire_complete_if_functional' depends on axioms: [propext]
'OneFire.first_match_is_a_determination' depends on axioms: [propext]
'OneFire.fresh_source_has_no_fire' depends on axioms: [propext]
'OneFire.finite_table_cannot_increment_everywhere' depends on axioms: [propext]
'OneFire.symbolic_fire_exact' does not depend on any axioms
'OneFire.symbolic_increment_everywhere' does not depend on any axioms
```

The file has no `sorry`, `admit`, or custom axiom. `propext` is a standard Lean axiom. The symbolic proof covers one arithmetic update only; it does not cover refusal, fault, ordered events, authorization, queries, outbox delivery, concurrency, or physical commit.

## Admissibility, determination, realization

- **Admissibility:** table membership or a symbolic equation states which pair is allowed.
- **Determination:** first-match order or a functional symbolic rule selects an output. The [selection proof](realization-boundary-report.md) shows that arbitrary symmetric admissibility cannot supply a representation-independent choice by itself.
- **Realization:** `fire?` returns a *value*. It does not durably write a record or deliver an external effect. A store/adapter must implement that boundary. The earlier [SQLite fault experiment](executable-relationship-report.md) checks one such contract empirically but does not formally verify SQLite.

The choice is now clear. A finite extensional relationship table gives one simple, transparent operation but fails unbounded Hecks behavior. Symbolic relationships can express unbounded changes, but the symbolic grammar and evaluator are substantive structure. An unrestricted relation parameter would hide any amount of code and make a “one construct” count vacuous. No theorem here equates the complete Hecks IR compiler, its eleven tested instruction tags, or physical adapters with this one-operation candidate.

**Current verdict:** one Relationship remains a plausible semantic foundation. A complete, non-opaque one-operation execution proof for Hecks was attempted and remains unestablished. To prove it, the rule language must be fixed and inspectable, its interpreter proved correct for the whole Hecks corpus, and its commit/port adapters shown to refine the specified relation. None of those obligations can be discharged merely by renaming them Relationship.

The ancestral checkout remained clean. No push, tag, release, or publication occurred.
