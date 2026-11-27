# Collection algebra — Hecks 8.0 proposal

Status: experimental; Lean compilation and runtime conformance pending.

Build on ADR 0126 and the existing Vocabulary Reducer rows. Do not introduce a competing reducer vocabulary or change existing Bluebook syntax initially.

## Semantic model
Typed select, project, group and reduce operations over collections. Distinguish reducer accumulator state from finalized answers. Preserve ordering, nulls, numeric bounds, refusals and aggregate consistency boundaries. Domain expressions must not acquire implicit repository access.

## Integration
1. Inventory existing expression grammar, BluebookIR and PrimalIR operators and predicate binding.
2. Compile CollectionAlgebra.lean with the repository's pinned Lean toolchain; integrate into its existing proof project.
3. Extend existing vocabulary only where a consumer requires it. Specify accumulator identity, lift, combine, finalize and optional removal.
4. Lower existing read-model syntax without observable changes.
5. Introduce typed local collection predicate binding if absent.
6. Add differential Ruby/Rust/WASM fixtures and property tests for filter/project fusion, partition equivalence, empty collections, nulls and refusals.
7. Investigate Rust integer reduction precision around 2^53; confirm whether upstream checks suffice.
8. Defer SQL pushdown and incremental execution until semantic equivalence is established.

## Acceptance
Existing corpus remains green; Lean checks pass without sorry; generated artifacts remain fresh; all runtimes agree on supported inputs. No new public syntax without a demonstrated need. Do not merge or promote before checks and review.

The candidate Lean module models pure lists and exact integer accumulation only. It does not prove equivalence to existing runtime implementations.
