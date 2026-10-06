# `MultiHeadBoard` — retention note

**Kept.** Holds the `multi_head_read_model` form of `Hecks::Fuzzing::FormCensus` beside the
forms the golden corpus never pairs it with.

## Why it exists

`FormCensus` gained two chapter-level forms: `cross_domain_policy` (an `across` policy,
attributed to the aggregate whose event it answers) and `multi_head_read_model` (a read model
composing two or more aggregate heads, attributed to each head). The goldens already pair
`cross_domain_policy` with every other form, but the only golden multi-head read model
(banking's `CustomerPortfolio`, headed by aggregates that carry few other forms) leaves three
pairs unmet: `multi_head_read_model` with `two_entities`, `multi_emit` and `has_default`.

`spec/combination_coverage_spec.rb` holds the form outside the goldens
(`HELD_OUTSIDE_THE_GOLDENS`) and names this domain as the holder: `Board` carries all four
at once. The staleness check there fires once the goldens pair them all, at which point the
entry and this domain's reason to exist are both gone.

## What it builds

`Board` (identity `code`): two entities (`Lane`, `Card`), a command emitting two events
(`Open`), a defaulted attribute (`capacity`), and a query. `Pin` references a board.
`BoardView` gathers a board and its pins as two heads of one read model.

## Not done

Ruby-only: no hecksagon, no Rust feature, no QualityControl `Target`. The measurement is the
census, not a differential run. Register it as a target if a sweep of it is wanted.
