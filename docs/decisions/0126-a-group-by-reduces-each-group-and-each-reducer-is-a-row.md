# A `group_by` reduces each group, and each reducer is a row

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-24.

## Context

A read model can nest rows with `group_by` or reduce them to one value with `count`, `sum`,
`avg`, `min`, `max`, `median`, `percentile`, `any` or `all` (ADR 0078), but not both:
`ReadModelBuilder#seal_aggregation` refuses the pair, and ADR 0078 left grouped reductions
out of scope. The report a ledger wants first, "the total of each kind", therefore cannot be
said. An ActiveRecord user writes `Payment.group(:status).sum(:amount)`; Hecks had no answer.

The reductions themselves were each written twice, in
`Runtime::ReadModelInterpreter::Reductions` and `rust/src/kernel/read_model.rs`, with what an
empty collection answers and how two partial answers combine held only in each runtime's code
and comments.

## Decision

1. **`group_by` and one reduction combine.** The rows nest one level per `group_by` field, as
   they do today, and each leaf is the reduction of that leaf's rows in place of the row:
   `group_by :status` with `sum :amount` answers `{ "captured" => 1200, "disputed" => 300 }`.
   Two reductions together, and the single-many-side-head rule, are still refused. A grouped
   reduction has no `group_by` collision to refuse: a leaf is a value, not a row.
2. **Each reducer is a row of the Vocabulary chapter's `Reducer` table**: its `name`, the
   `identity` it answers over no rows, the `combine` that folds two partial answers, and the
   `inverse` that takes one partial answer back out, empty where none exists. `count` and
   `sum` combine by `add` and invert by `subtract`; `min`/`max` combine by `min`/`max`;
   `any`/`all` by `or`/`and`; `avg`, `median` and `percentile` do not combine (`collect`):
   their partial answers do not add up to the whole.
3. **Both runtimes read the rows.** `project_vocabulary` puts them in `lib/hecks/vocabulary.rb`
   and `project_rust_vocabulary` in `rust/src/kernel/vocab/reducer.rs`. Ruby and Rust answer an
   empty collection from `identity`. The fuzzer's `aggregation_matches_recompute` property
   folds a grouped answer's leaves by `combine` and compares the result with the ungrouped
   reduction of the same rows, for every reducer whose `combine` is not `collect`;
   `group_by_matches_recompute` compares every leaf with the reduction recomputed over that
   leaf's rows.
4. **No new word, so no attached sub-language.** The grammar already holds `group_by` and every
   reducer (projection.bluebook); this change lifts a refusal and adds a closed set. A chapter
   that attaches to `ReadModel` (ADR 0026, as Paging does) holds words; the reducer algebra is
   a closed set the projections already read from Vocabulary, so it lives there.

## Alternatives considered

- **An `aggregate_by` word** beside `group_by`. Rejected: it is the same shape with a second
  spelling, against ADR 0025's one idea, one way.
- **A `Reducers` chapter attached to `ReadModel`.** Rejected for now: the vocabulary
  projections read only the Vocabulary chapter, and moving the reducer words themselves out of
  the core grammar is a separate change with no reader asking for it.
- **SQL pushdown of grouped reductions.** Out of scope here, as ungrouped reductions are not
  pushed down either. The `Reducer` rows carry no SQL column until a translation reads one
  (ADR 0026: the language declares only what it uses).

## Consequences

- `examples/banking` shows `CardPaymentTotalsByStatus` (`group_by :status`, `sum :amount`).
- The generated Rust calls `read_model::nest_reduced` from the per-read-model group function;
  the generator no longer skips a read model that groups and reduces.
- A conformance-corpus case (`grouped_reduction.json`) freezes the answer both runtimes give.
