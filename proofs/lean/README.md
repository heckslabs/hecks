# Hecks 8.0 formal verification: Lean project

Seven Lean 4 modules on a pinned toolchain (`lean-toolchain`: Lean 4.36.0). Build: `cd proofs/lean && lake build`.

| Module | What it states |
|---|---|
| `RelationshipExperiment` | relation laws: a Condition as a subidentity relation, associativity, congruence, invariant preservation over chains |
| `OneFire` | one executable `fire?` over a finite table: sound, complete when functional, cannot implement an unbounded update; a symbolic rule repairs it |
| `CrystalExperiment` | the reduction of Hecks command semantics to relations, with counterexamples |
| `ExecutableRelationship` | a model interpreter realizes the relation; commit atomicity; refusal does not commit |
| `AuthorityRelationship` | authority as a condition plus an enforcement boundary; noninterference under its stated premises |
| `RealizationBoundary` | selecting one outcome needs a determination rule; no equivariant selector |
| `PreStateEffects` | effects read the pre-command state; the sequential reading is a counterexample |

## Status (2026-11-27)
- Source: the Codex session of 2026-11-27, unchanged. Unreviewed.
- `lake build` passes on Lean 4.36.0; `leanchecker` (the independent kernel checker) passes on all seven modules. No `sorry`, no `admit`, no `axiom` declarations of its own.
- Theorems depend on `propext`; some also on `Classical.choice` and `Quot.sound` (Lean's standard three). No allow-list has been approved yet.
- These prove properties of the model. They do not prove that the Ruby or Rust compilers implement it; conformance on the 52 frozen fixtures in `spec/corpus/semantics` is a separate, executable claim.
