# The smallest remaining boundary: choosing and doing

## Answer to the three-part question

| Layer | Precise meaning | Relationship can express it? | Remaining obligation |
|---|---|---|---|
| **Admissibility** | `A(s,t)`: output `t` is allowed from `s`. | Yes, directly. | Explain the rule's data and evaluator. |
| **Determination** | A narrower relation `D(s,t)` within `A`, preferably total and single-valued. | Yes: `D` is also a relation. | Specify how a choice is resolved: priority, order, scheduler, or a deterministic rule. |
| **Realization** | A witnessed transition actually performed, with observable durable/external consequences. | Its *contract* can be a relation over full physical configurations. | An executor/adapter must perform it and provide evidence that it did. Logical truth alone does not cause a write. |

So these can be **three uses of one mathematical type**. They are not automatically one executable operation. The smallest gap is the move from “an allowed output exists” to “this output was selected and caused.” A deterministic relation can encode the selection; a generic interpreter still has to evaluate it, and a store/port still has to carry out the effect.

## What Lean established

[RealizationBoundary.lean](RealizationBoundary.lean) defines `Total`, `Realizer`, `Refines`, and `SingleValued` over the same `Rel A B` used in the prior algebra. It checks:

1. A witnessed output of a determined relation is admissible when determination refines admissibility.
2. Two distinct single-valued determinations can both refine the same admissible relation (`true` and `false` are both allowed). Therefore admissibility does not determine a result.
3. There is **no selector invariant under renaming** that chooses from *every* Boolean relation and commutes with flipping `true` and `false`. The full relation is unchanged by that flip; its chosen Boolean would have to equal its opposite. This is a scoped impossibility result. An explicit priority order or other asymmetric data can break the symmetry.
4. Identity and composition with no nonidentity generator always denote identity. They cannot even force a Boolean state to `true`. A generator must carry the change, or an unrestricted arbitrary relation must hide it.
5. Classical logic can obtain a witness from a total relation via `Classical.choice`, but that definition is noncomputable. It is not an executable scheduler or a durable store.

Command: `LEAN_PATH=work work/lean-4.36.0-darwin/bin/lean outputs/RealizationBoundary.lean`  
Exit status: `0`; standard error: empty. Exact standard output in [realization-lean-check.txt](realization-lean-check.txt):

```text
'RealizationBoundary.full_is_flip_invariant' depends on axioms: [propext]
'RealizationBoundary.no_equivariant_selector' depends on axioms: [propext]
'RealizationBoundary.chosen_true_is_unique' does not depend on any axioms
'RealizationBoundary.determined_witness_is_admissible' does not depend on any axioms
'RealizationBoundary.both_choices_refine_full' does not depend on any axioms
'RealizationBoundary.both_choices_are_single_valued' does not depend on any axioms
'RealizationBoundary.determinations_can_disagree' does not depend on any axioms
'RealizationBoundary.classicalRealizer' depends on axioms: [Classical.choice]
'RealizationBoundary.composition_only_is_identity' depends on axioms: [propext, Quot.sound]
'RealizationBoundary.composition_only_cannot_force_true' depends on axioms: [propext, Quot.sound]
```

The file contains no `sorry`, `admit`, or custom axiom. `propext`, `Quot.sound`, and `Classical.choice` are standard Lean axioms. The impossibility theorem assumes renaming invariance and the selector's equivariance; it does **not** prove that every one-operation implementation is impossible.

## Architectural consequence

The kernel could plausibly shrink to a generic, inspectable **realization boundary**: match a declared relationship, establish a selected successor or a refusal/fault, then atomically publish the specified state/event/outbox changes. Its rule data would be manifested structure; its physical transaction, scheduler, and adapter contracts would remain explicit. Calling that boundary `Relationship` is coherent only if these contracts are visible and independently verified.

This is not a proof that the kernel can disappear. The earlier [SQLite fault test](executable-relationship-report.md) shows why: when an error occurs between a record and event write, the transaction must roll both back. The relation specifies that requirement; SQLite supplies the causal mechanism. The [IR compiler test](final-crystal-era-verdict.md) likewise shows that source rules can be lowered to inspectable data, but the interpreter still implements eleven instruction types in the tested slice.

**Research verdict:** one semantic type remains plausible. The smallest remaining behavior to account for is **determined, witnessed, physically realized transition**. Whether it counts as another irreducible *architectural* construct depends on whether the generic realization boundary can be made small, transparent, and proven to refine the declared relationships across all Hecks behaviors. That has not been established here.

The ancestral checkout remained clean. No push, tag, release, or publication occurred.
