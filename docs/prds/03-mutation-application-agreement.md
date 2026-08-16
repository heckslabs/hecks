# PRD 03 — Cross-adapter differential testing for mutation application

**Status:** Not started. Two viable build orders — see below.

## The problem

`spec/adapters/query_agreement_spec.rb` holds Memory/Sqlite/PostgresEra/
Postgres/D1 to an **independent, hand-computed oracle** for every query
comparator, ordering mode, paging offset, and null-handling case — its own
stated reasoning is that pairwise agreement alone is insufficient ("three
engines sharing one bug would still 'agree'"). That discipline has found
four real bugs.

Nothing equivalent exists for **mutation application** — `append`, `remove`,
`multiply`, `clamp`, `increment`/`decrement`, `set`. `spec/adapters/
banking_matrix_spec.rb` boots the same domain across several adapters and
dispatches commands, which incidentally exercises this, but it isn't framed
as an explicit differential gate the way `query_agreement_spec.rb` is — a
divergence there would have to be noticed by a spec author, not asserted by
the harness.

## Two ways to build this — pick one, both are complete answers

**Path A — hand-written, ships independently, no prerequisites.** A new
`spec/adapters/mutation_agreement_spec.rb`, same shape as
`query_agreement_spec.rb`: pick a handful of real declared mutations
(an entity `append` with a composite identity, a `remove` by value equality,
a VO-typed `multiply`/`clamp` pair — real corpus sites, not synthetic ones),
dispatch the same command against Memory/Sqlite/Postgres in turn, and assert
the stored result matches an independently-computed expected value (not just
that all three adapters merely agree with each other).

**Path B — an extension of PRD 02.** Once the fuzzer/property suite runs
against real adapters (`02`), this becomes close to free: run the *same*
generated sequence against Memory and Sqlite in the same replay, and add one
more property — `mutation_application_agrees_across_adapters` — comparing
the two engines' own final `instances` for the same replayed steps. This is
the *pairwise* form the query spec's own reasoning warns is insufficient
alone, but combined with `mutations_match_recompute`'s already-existing
independent-recompute check (which neither engine gets to see), the
combination closes the same gap `query_agreement_spec.rb` closes with one
oracle instead of two engines.

## Approach

Whichever path is picked, ground it in real corpus sites, not a synthetic
fixture — `Account.Credit`'s `:ledger` append, `SafeDepositBox.LogVisit`'s
composite-identity append, `TaggedList`'s `multiply`/`clamp` pair
(`spec/fixtures/entity_list_mutations`, now a real bootable domain per this
session's own work) are all real, already-exercised mutation sites across
more than one adapter binding today.

## Acceptance criteria

- [ ] At least one `append`, one `remove`, one `multiply`, and one `clamp`
      site is checked cross-adapter, against an independent expectation
      (not just adapter-vs-adapter agreement, even under Path B).
- [ ] Any real divergence found gets fixed, not special-cased.
- [ ] Whichever path is chosen, the other path's own value is still
      achievable later without rework — Path A's hand-written spec doesn't
      block Path B's later fuzzer-extension property, and vice versa.

## Non-goals

- Every mutation op in the language — this is a differential *gate*, not
  exhaustive coverage; `query_agreement_spec.rb` itself only covers eight
  comparators deliberately, not every possible query shape.
- Adapter-internal concurrency (locking behavior under simultaneous writes)
  — that's PRD 01's territory, a different question from "does the same
  single-threaded mutation land the same way on two engines."
