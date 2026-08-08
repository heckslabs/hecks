# `report` is the business-facing spelling of a read model

**Status:** Accepted — implemented (`bluebook_builder.rb`, `syntax.bluebook` via `bin/evolve rename`, `docs/reference/`)

## Context

Hecks already had `read_model`, but the word doesn't read as business vocabulary — it names an implementation pattern, not something an SME would say. The roadmap wanted `report` as the primary, taught spelling, with `read_model` demoted rather than removed, following this project's existing convention for keyword renames (`sets`/`then_set` is the precedent: the new spelling is what's taught, the old spelling is aliased and kept alive permanently).

Two constraints shaped how far the rename could go:

1. **Held era text is integrity-checked, not just historical.** `EraTamper` compares a plain SHA256 over a held era's frozen text; the refusal wording is explicit that "held era texts are storage facts." `bin/reattest_era`'s digest-mismatch judgment and legacy-row backfill both re-execute that frozen text as live Ruby (`Reattest.shape_guard!`, `EraStore`'s backfill path). If `read_model` stopped existing as a callable method, those paths would raise `NoMethodError` against any era whose frozen source still says `read_model` — which real held eras (Banking era 1, Pizzas era 1) do.
2. **This is the project's own enforced convention, not just a judgment call.** `bin/evolve rename`'s own printed output says "the old spelling keeps parsing — that is the point," and `spec/syntax_conformance_spec.rb` statically asserts that both a renamed word's old and new spellings are answerable by the live Ruby builder. Removing `read_model` outright fails an existing test, independent of the era-integrity argument above.

We also investigated whether minting a new era could carry the rename forward instead of keeping `read_model` alive. It can't help here: era-minting is driven by comparing canonical IR shape (`Runtime::StorageShape.project`) between the live declaration and the latest held era, not by diffing Ruby source text. Since `report` and `read_model` build byte-identical `IR::ReadModel` nodes, there is no shape difference for the minting mechanism to ever see — it would be a quiet reboot, not a mint. And even if an era *were* minted, it wouldn't touch an earlier era's independent digest check, which is keyed to that era's own row.

## Decision

- `Bluebook::DSL::BluebookBuilder#report` is the primary method; `read_model` is `alias_method`'d to it, kept alive permanently — the same shape as `sets`/`then_set`.
- The self-hosted grammar was updated through the actual tool, not by hand: `bin/evolve rename read_model --context Bluebook --to report`, which rewrote `syntax.bluebook`'s row to `word: "report", context: "Bluebook", ..., was: "read_model"`, regenerated the golden IR, and ran its own gates (`syntax_conformance_spec`, `syntax_lifecycle_spec`, `ir_golden_spec`).
- All *live* `.bluebook` authoring sources were moved to `report`: `examples/banking/bluebook/banking.bluebook`, the self-hosted `lib/hecksagain/language/bluebook/bluebook.bluebook`, and `spec/fixtures/reflex.bluebook`.
- Frozen held-era text (`examples/banking/data/eras/banking/1.bluebook` and its `archive/` copy) was deliberately left untouched — editing it would trip the tamper detector it exists to trigger.
- `docs/reference/` was regenerated via `bin/reference`, with the prose for the renamed word hand-updated (the generator refuses to silently drop prose for a word the language no longer declares by its old name).

## Consequences

- `report` and `read_model` produce byte-identical IR — enforced by a regression test (`spec/dsl_spec.rb`, "builds the same read model under report and read_model — a rename, not a fork").
- New authoring, new docs, and the DSL coverage spec (`spec/dsl_coverage_spec.rb`) all teach `report` as the word going forward.
- `read_model` remains permanently callable but undocumented — existing Ruby source using it keeps working with zero migration pressure, and held-era reattestation keeps working indefinitely.
- The rename's provenance (`report` *was* `read_model`) is a durable fact in `syntax.bluebook`, not just this document — `bin/evolve status` reports it alongside `Command.sets (was then_set)`.

## Rejected alternatives

- **`read_model` disappears entirely from the DSL.** Breaks `bin/reattest_era` against any held era whose frozen text still says `read_model` (a real, current fact for Banking and Pizzas era 1), and fails `spec/syntax_conformance_spec.rb`'s existing assertion that a rename keeps both spellings live.
- **Mint a new era to carry the rename forward, leaving era 1 untouched.** Investigated directly: era-minting is IR-shape-driven, and this rename produces identical IR, so nothing would ever be minted — there's no shape delta for the mechanism to see. Even in principle, minting a later era does nothing to era 1's own, independent digest check.
