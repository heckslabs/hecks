# The newcomer path is a Memory-default console and a short README

**Status:** Accepted — implemented in 2.8.0. Date: 2026-09-27. A bare `bin/console` boots the Memory-bound pizzas hecksagon, and the README is a pitch, a quickstart and a glossary, with the status and projection material in guides. The open items below still stand.

## Context

A newcomer meets bluebook, hecksagon, world, Heki, era, PostgresEra, chapter, door and corpus within minutes, in a README of 769 lines. The first thing they can run from a terminal is `bin/console examples/banking`, in the Quickstart at `README.md:653`, about 85% of the way down. The Install section never mentions the clone that command needs (`docs/wayfinder/review-followup/tickets/08-newcomer-path.md`).

The bare `bin/console` needs Postgres. It requires the PostgresEra plugin unconditionally (`bin/console:18`) and boots `examples/pizzas`, whose hecksagon says `persisted_by("PostgresEra")` (`examples/pizzas/bluebook/pizzas.hecksagon:8`). A Memory-bound sibling already exists (`examples/pizzas/pizzas_behaviors.hecksagon:12`), and the README's own hidden doctest boot binds pizzas to Memory (`README.md:22-28`). The Quickstart works around this by steering readers to banking and warning that pizzas needs Postgres.

Jargon appears before it is explained: corpus (`README.md:109`, never defined), chapter (line 424, never defined), embryonaut bluebook (line 751, never defined) and bare "era" (line 618, never defined). No glossary of the project's vocabulary exists in `docs/` or the README.

`docs/implemented/guides/getting-started.md` contradicts the tree in two places. Line 18 says "currently 1.0.2", which [ADR 0070](0070-docs-carry-dated-snapshot-banners-and-a-stale-version-guard.md) flags. Line 31 says banking boots against the in-memory adapter, but banking is bound to Heki (`examples/banking/bluebook/banking.hecksagon:9`). Banking's `data/*.heki`, journals and `banking_projection.sqlite3` are git-tracked, so a Quickstart dispatch dirties tracked files in a clone.

A rewrite has to respect the doctest gate. The README is one doctested guide sharing a Ruby namespace with the others, so the `Order` chapter name must stay unique (`spec/support/doctest_names.rb`, `spec/guides_spec.rb`). `spec/doc_skip_fence_caps_spec.rb` pins exactly 5 `ruby skip` fences for `README.md`. `spec/readme_version_spec.rb` needs two "Current release" lines (`README.md:49`, `README.md:571`), and `spec/readme_planned_adrs_spec.rb` needs the planned list. Prose outside fences is unguarded, and top-level `docs/*.md` is ungated unless listed in `UNGATED_STATUS_DOCS` (`spec/support/doctest_names.rb:73`).

## Decision

1. **The default `bin/console` boots the existing Memory-bound pizzas hecksagon**, so a bare console needs no Postgres. The domain stays pizzas.
2. **Rewrite `README.md` as a pitch, a 10-minute quickstart within the first 60 lines, and a glossary linked on first use.** Project-status and projection material moves into doctested guides under `docs/implemented/guides`, so it stays under the doctest gate.
3. **Fix `getting-started.md` in the same change:** the stale version at line 18 and the in-memory claim about banking at line 31.

## Consequences

- A bare `bin/console` works on a clean clone with no server. The default console domain is the one the guides walk through, and it no longer matches the domain its own PostgresEra wiring describes; the Postgres-backed pizzas wiring stays available for the schema-evolution guide.
- The gem gives an evaluator the `hecks` command ([ADR 0066](0066-the-gem-ships-a-hecks-executable-and-dev-tooling-stays-in-the-repo.md)) but no sample domain, so the quickstart still starts from a clone. `gem install hecks` alone does not reach the first ten minutes.
- Moving material into guides keeps it doctested; the rewrite must re-pin the skip-fence cap, the two "Current release" lines and the planned list, and must keep the `Order` chapter name unique.
- The README's shape is guarded only inside its fences. Nothing checks that the quickstart stays within the first 60 lines.

## Alternatives considered

- **Console default only.** Small and removes the Postgres requirement, but the README still buries the quickstart and leaves undefined vocabulary.
- **README rewrite only.** Fixes the reading order, but the default console still needs Postgres and the quickstart keeps a workaround for it.
- **Leave as is.** No risk, but the newcomer keeps a 769-line README, a console that needs a database, and two wrong statements in the getting-started guide.

## Open items

- May banking's git-tracked example data (`data/*.heki`, journals, `banking_projection.sqlite3`) be dirtied by a quickstart dispatch, or should the quickstart point it at a temporary location?
- Where does the glossary live: a doctested guide, which needs a runnable fence, or an ungated top-level doc, which needs an `UNGATED_STATUS_DOCS` entry?
- Is "era" newcomer vocabulary at all, or does it stay behind PostgresEra in the schema-evolution guide?
- Should the default console domain stay pizzas on Memory, or become banking? This ADR says pizzas on Memory; the question is whether that holds once banking is the domain the quickstart uses.
- Should a spec keep the quickstart inside the first 60 lines, or is that a review-time convention?
