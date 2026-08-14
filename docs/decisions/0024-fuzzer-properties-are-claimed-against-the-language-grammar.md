# A fuzzer property declares which language feature it covers, and the meta-domain enforces that every feature is claimed

**Status:** Accepted — implemented. `lib/hecksagain/fuzzing/properties.rb` (`Properties::FEATURE_COVERAGE`), `spec/fuzzing/meta_domain_coverage_spec.rb`.

## Context

`bin/fuzz` already closed half of property-based testing: `SequenceGenerator` derives random-but-valid command/query sequences from a domain's own IR, `Replay` runs one in-process and records what happened, and the shrinker minimizes any failure to the fewest steps that still reproduce it. What it checked, until now, was "did the interpreter crash" and three hand-written properties (`lifecycle_values_are_declared`, `saga_advances_follow_declared_handlers`, `query_answers_match_reference`) — real, but chosen once, by hand, with nothing tying them to the language's own surface.

That gap showed up concretely: four pieces of new language surface landed in one session — saga checkpoint/rehydration durability, banking's cross-aggregate status guards (`given`/`ensures` on 58 commands), policy `where`/`for_each` fan-out dispatch, and read-model `count`/`median` aggregation — and none of them had a corresponding property. Nothing had refused to let that happen; a new construct simply shipped without anyone asking "does the fuzzer check this."

The language is not an ad hoc thing to enumerate by hand for this purpose, either. `Bluebook::MetaValidator.grammar_registry` already IS the language — every real bluebook is judged against it, loaded from `language/bluebook/*.bluebook`, the same self-hosted grammar `spec/combination_coverage_spec.rb`'s own pairwise form gate already leans on (that spec's own header: "Adding a property here is how a new form joins the gate — it will name its own uncovered pairs on the first run"). This decision applies that exact idea one level up: not "is this form exercised," but "does a checked INVARIANT exist for this feature, or was it left to ship silently."

## Decision

Four new properties were added, each answering one of the four gaps named above (`guard_refusals_are_declared`, `sagas_rehydrate_cleanly`, `fanout_dispatches_once_per_matching_row`, `aggregation_matches_recompute` — see `properties.rb`'s own comments for what each checks and why). More load-bearing than any one property: every property, new and old, now declares which `"Construct#attribute"` of the meta-domain's own grammar it covers, in `Properties::FEATURE_COVERAGE`.

`spec/fuzzing/meta_domain_coverage_spec.rb` reads `MetaValidator.grammar_registry` directly (never a second, hand-typed list of constructs) and enumerates every attribute every declared construct carries. For each one, it demands exactly one of three things be true, on the record:

- a property in `FEATURE_COVERAGE` claims it,
- it is structural bookkeeping that carries no behavior of its own to have wrong (an identity/foreign-key column, a position index, a human-facing label — `META_DOMAIN_STRUCTURAL_FEATURES`), or
- it is a named, itemized `META_DOMAIN_KNOWN_GAPS` entry — a real feature this arc did not reach, with a one-line reason, so "unclaimed" can never quietly mean "unnoticed."

The same spec also checks the reverse direction: every `FEATURE_COVERAGE` entry names a feature the live grammar still declares, so a rename or removal leaves a stale claim failing loudly rather than silently protecting nothing.

## Consequences

- A construct added to `language/bluebook/*.bluebook` — a new attribute on `Command`, a new construct entirely — fails `meta_domain_coverage_spec.rb` the next run, naming exactly what's unclaimed, unless someone makes a deliberate coverage decision for it. That is the mechanism this decision exists for: "add to the language, and the property gap announces itself," not "add to the language, and hope someone remembers to check the fuzzer."
- `META_DOMAIN_KNOWN_GAPS` is not decoration and is not meant to be comfortable — every entry is a real feature with no invariant, visible in the same file the gate itself lives in. Closing one converts it from a `KNOWN_GAPS` line to a real property with its own failing-and-passing spec (`spec/fuzzing/properties_spec.rb`'s own "each property, seen failing" discipline — a property nothing can ever fail is decoration, the same lesson `combination_coverage_spec.rb` states for declarations generally).
- This does not make every property automatically DISCOVERABLE by generated sequences — only checkable. `SequenceGenerator` does not yet ask read-model reports or exercise a `for_each` policy (no example domain declares one), so `aggregation_matches_recompute` and `fanout_dispatches_once_per_matching_row` are real, shrinkable properties the moment a history exercises them, but nothing in the corpus today makes that happen on its own. Closing THAT gap — generator coverage, not property coverage — is separate, unstarted work.
- A per-property oracle has to stay independent of the code path it's checking, the same discipline `query_answers_match_reference` already established (two engines, never one graded against itself). `fanout_dispatches_once_per_matching_row`'s own oracle recomputes expected fan-out rows from a PRE-DISPATCH snapshot rather than the live registry — a real ordering bug (the fan-out's own dispatches mutate the rows mid-call) that a first version of this property, and its own adversarial spec, caught before this landed.

## Rejected alternatives

- **Keep hand-picking properties, as before.** This is the status quo the Context section describes failing — four real gaps shipped with nobody deciding whether the fuzzer should check them. Rejected because the failure was structural (no mechanism forcing the question), not a one-off oversight a sharper reviewer would have caught next time.
- **Generate properties FROM the grammar automatically**, rather than declaring coverage and gating on it. Considered and set aside: a property is a judgment about WHAT invariant matters for a feature (e.g. "median averages the two middle values as a Float, not an Integer" is a specific, non-obvious claim), not something derivable mechanically from an attribute's mere existence the way IR shape or a pairwise combination is. The gate keeps that judgment call human and explicit; only the ENUMERATION of what needs a judgment call is automatic.
- **Express the four new invariants as `given`/`ensures` rules inside the meta-domain itself** (the language's own build-time validation), rather than as replay-time fuzzer properties. Rejected for this pass because the four gaps are runtime facts about a REAL RUN (did a saga's memory survive a checkpoint round-trip, did a fan-out dispatch to the right rows) — not shape facts a static judge over one bluebook's declarations could check without executing anything. `docs/decisions/0009` already draws this exact boundary for the language generally: shape is self-hosted, behavior is not.
