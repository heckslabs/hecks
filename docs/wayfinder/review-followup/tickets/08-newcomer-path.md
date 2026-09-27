---
type: grilling
status: open
blocked_by: [04-distribution-shape]
claimed_by:
---

# Newcomer path: README shape, glossary, zero-setup start

## Question

A newcomer meets bluebook, hecksagon, world, heki, era, PostgresEra, chapter, door, and corpus
within minutes, in a 37 KB README. The default `bin/console` domain needs Postgres. Decide the
README's shape (pitch plus quickstart, glossary linked on first use), what the zero-setup path
is and that it is the default, and what the first ten minutes run given the distribution shape.

## Prep (not a decision)

Gathered by a read-only agent for the grilling session. This ticket waits on *Distribution
shape*, so every option is conditional on it.

**Facts**
- `README.md` is 769 lines, about 37 KB. The intro (lines 1-52) holds the first runnable fence
  (line 35, booted by a hidden `doctest:boot`). Install is only `gem install hecks`. The
  Quickstart starts at line 653, about 85% of the way down, and the first thing a newcomer can
  run from a terminal, `bin/console examples/banking` (line 663), needs a clone that Install
  never mentions.
- Jargon, by first use: bluebook (line 3, glossed), hecksagon (line 147, defined inline),
  world (148, defined inline), corpus (109, never defined), Heki (395, defined in
  parentheses), PostgresEra (393, defined), door (523, defined in the following lines),
  chapter (424, never defined), storehouse (523, only implied), embryonaut bluebook (751,
  never defined), and bare "era" (618, never defined). There is no glossary of hecks vocabulary
  in `docs/` or the README; the `glossary/` files under the examples are per-domain.
- Zero-setup: `bin/console` boots `examples/pizzas` and requires the PostgresEra plugin
  unconditionally (line 17); pizzas' hecksagon says `persisted_by("PostgresEra")`. A
  Memory-bound sibling already exists (`examples/pizzas/pizzas_behaviors.hecksagon:12`), and the
  README's own hidden doctest boot binds pizzas to Memory. The Quickstart already steers
  newcomers to banking and warns that a bare `bin/console` needs Postgres (lines 678-681).
- Banking is bound to Heki, not the in-memory adapter. The agent copied banking out of the repo
  and ran the README's register, open, credit and balance sequence with no Postgres; it worked
  and printed one Heki-has-no-outbox warning. It did not run `bin/console` itself. It also
  booted a pizzas copy with the era plugin against this machine's live Postgres, which may have
  touched the local `hecks_pizzas` database; that was not checked.
- Doc conflicts: `docs/implemented/guides/getting-started.md:30` says banking boots against the
  in-memory adapter (the hecksagon says Heki) and line 15 says "currently 1.0.2".
- Banking's `data/*.heki`, journals and `banking_projection.sqlite3` are git-tracked, so the
  Quickstart's dispatches dirty tracked files in a clone.
- Doctest wiring a rewrite must respect: the README is one doctested guide sharing a namespace
  with the others (the `Order` chapter name must stay unique); `spec/doc_skip_fence_caps_spec.rb`
  pins exactly 5 `ruby skip` fences; `spec/readme_version_spec.rb` needs two "Current release"
  lines; `spec/readme_planned_adrs_spec.rb` needs the planned list; links and no-counts specs
  cover it. Prose outside fences is unguarded. Top-level `docs/*.md` is ungated by design, so
  moved text needs a doctested guide or an `UNGATED_STATUS_DOCS` entry.

**Options**
1. Quickstart README plus a term glossary linked on first use. Needs a home for the glossary
   and re-pinned caps and version anchors.
2. Option 1 plus moving reference material (project status, projections, AI-native, the docs
   index) into `docs/`, shrinking the README by about half. Moved text leaves the doctest gate
   unless it lands in a guide.
3. A zero-setup `bin/console` default, reusing the existing Memory-bound pizzas hecksagon. The
   default then differs from the domain the guides walk through unless that binding is reused.
4. Leave as is.

**Recommendation from prep.** Options 2 and 3 together, in this order: switch the default
console to the Memory-bound pizzas hecksagon; then rewrite the README as pitch, a 10-minute
quickstart within the first 60 lines and a linked glossary, moving status and projection
material into doctested guides; fix `getting-started.md` in the same change. If the
distribution decision is gem-only, the quickstart cannot rely on a clone and `examples/` would
have to ship in the gem; under a clone distribution, point banking's `data/` at a temp or
gitignored location.

**For the maintainer**
1. Does the distribution decision make the clone or the gem the newcomer's entry point?
2. Should the default console domain stay pizzas on Memory, or become banking?
3. Should the glossary live in a doctested guide (needs a runnable fence) or ungated top-level
   `docs/` (needs an allow-list entry)?
4. Is it acceptable for a Quickstart dispatch to write to git-tracked example data?
5. Is "era" newcomer vocabulary at all, or does it stay behind PostgresEra in the schema-evolution
   guide?

## Answer
