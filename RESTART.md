# Restart prompt — hecksagain, projecting the parser

Paste this into a fresh session. Read `README.md` and `HANDOVER.md` first; **HANDOVER
is stale in places** (it predates the projection work and still says "Do not call Rust
a projection"). This file is newer and wins where they disagree.

---

## Where things stand

`main` at `2bf5cd5`, pushed, clean. Gates:

    bundle exec rspec                             700 examples, 0 failures
    cd rust && cargo test --release --workspace   passing, 0 warnings
    bin/parity                                    AGREED, 15 stages, 120 mutants

`core.hooksPath` is LOCAL config — a fresh clone needs
`git config core.hooksPath .githooks` or the pre-push parity gate is silent.

## THE NEXT TASK, AND ITS BLOCKER

**Goal: project the PARSER from the language.** That is where the value is — the
shapes projection buys almost nothing (see "what the projection is actually worth"
below), and every bug this arc found lived in hand-written parsing and reading.

**It is blocked, and the blocker is the task.** The language declares SHAPE, not
SPELLING. `lib/hecksagain/language/bluebook/*.bluebook` say an `Aggregate` has
`identified_by: list_of(IdentityPath)` and a `Field` has a name, a type and a
cardinality. Nothing anywhere says that the field is spelled `identified_by`, that a
block opens with `do`, or that a symbol argument starts with `:`. Grep those files for
keyword/token/syntax and the only hit is a comment.

So a projected parser needs the language to declare its own syntax FIRST. That is a
language-design change, not a generator.

**Why this is exactly the right diagnosis, not a dodge:** when `identified_by` became
`list_of(IdentityPath)`, the PROJECTED struct regenerated to `Vec<String>` and was
correct with nobody touching it. Both hand-written halves broke — Rust's parser could
not read `identified_by do` at all (it swallowed whole aggregate bodies, silently) and
the dispatcher read the field with `as_str`, got `None` on an array, and fell through
to a minted `"id"`. The declared half survived; the undeclared halves did not.

### The first step

Give the language a syntax layer: each category's fields gaining the KEYWORD that
spells them, and which forms they accept (inline `{ … }`, block `do … end`, bare
symbol). Two existing hand-written inventories to lift from rather than invent:

- `rust/src/runtime/strict_boot.rs` — a keyword list with "did you mean" suggestions.
  It exists ONLY because nothing declares what the keywords are.
- `bin/ir_structs`'s emitted header — the map of where the language already comes up
  short (`Lifecycle`, `OrderBy`, `Direction`, `LimitSpec`, `ValueSpec` have no language
  source; `Query.limit`, `ValueObject.members`, `Policy.aggregate` are real divergences).

Bluebook first, and it is not optional — `bluebook.bluebook` is where this goes.

## WHAT THE PROJECTION IS ACTUALLY WORTH (do not oversell it)

This was interrogated hard at the end of the last session and the honest answer is
smaller than the commit messages suggest. Carry the honest version:

- `bin/ir_structs` (10 structs) + `bin/ir_vocabulary` (2 enums) generate ~300 of
  ~8000 Rust lines. **`bin/parity` already caught shape drift** — Ruby's `to_h` vs
  Rust's `--dump` splits when the language gains a field Rust lacks. All ten projected
  structs are exercised by banking, so for everything it covers, parity had it.
- It did NOT enable `bin/ir_rust` either — the domain projection needs the struct
  DEFINITIONS to exist, not to be generated.
- What survives: one narrow gap (parity only sees what the corpus reaches; a field on
  a category the corpus never exercises — the language's own `Member`, `Handler`,
  `Dispatch` — never reaches it), one fewer hand-maintained artifact, and the
  generator's exclusion header as a measured map of where "the spec is the system"
  is not true yet.
- **The value is in writing the generator, not running it**: you cannot emit a field
  the language does not declare, so building one forces a field-by-field audit.
- It is only worth its weight if the ladder continues. Shapes were never where the
  money was.

## The projection as it stands

    bin/ir_structs     language -> 10 Rust struct declarations   (rust/src/bluebook/ir_structs.rs)
    bin/ir_vocabulary  Vocabulary -> 2 Rust enums                (rust/src/bluebook/ir_vocabulary.rs)
    bin/ir_rust <bluebook>  a DOMAIN -> Rust values              (rust/src/bluebook/projected/*.rs)

Seven chapters compile in: Banking, Expression, Market, Pizzas, Relay, TillRoom, Wire.
**Reflex is excluded BY NAME** — it declares every query option the language holds and
Rust's `Query` struct carries none, so there is nowhere to project them.

- `Runtime::boot` prefers a projection over parsing; `Runtime::boot_projected(chapter)`
  boots with NO file at all. `bin/parity` runs the whole corpus with Rust booting from
  projections.
- **A projection is SEALED to its source** by SHA (`SOURCE_SHA` in each projected file,
  checked by `projected::by_source`). Name-only lookup hijacked any same-named chapter
  — a router test's own `Banking` fixture got the real banking — and kept answering
  after its source was edited. Do not weaken that seal.
- `bin/ir_rust` takes a BLUEBOOK, not a domain directory. Booting mints an era into the
  tree it reads, so a directory-taking generator could not be run twice.
- Two checks: `spec/ir_rust_export_spec.rb` holds each file equal to the generator
  (determinism); `bluebook::projected::tests` flattens the projected domain back through
  `ir_json::domain_to_value` and diffs it against `spec/golden/ir/*.json`, which is
  Ruby's own frozen `to_h` (correctness). **The second is the one that matters** — it
  found three inversion bugs the moment six more chapters were projected.

## The typed seam (item 2, partly done)

`Runtime` now holds the typed `Domain`; `ir: Value` is derived from it in `new`. Only
the identity reader has moved over (`identity::of_paths`, via `declared_identity`).
**~195 `.get("…")` reads remain** across `dispatcher.rs` and `mutations.rs`. Converting
them blind would leave TWO sources of truth — the seam exists so they move one at a
time. Caveat: `resolve_admitted_sets` annotates the JSON AFTER derivation, so `ir` is
derived-then-annotated, not a pure projection.

## Coverage gates — all three allowlists are EMPTY, keep them that way

    spec/plurality_coverage_spec.rb     every declared list filled with >1 somewhere
    spec/optionality_coverage_spec.rb   every nullable wire field filled somewhere
    spec/combination_coverage_spec.rb   all 78 pairs of 13 forms met on one aggregate

Each fails in BOTH directions — an excuse the corpus has outgrown fails too. Adding a
property to the combination gate makes it name its own uncovered pairs immediately.

**These found five things no test went red for**: `emits` never announcing twice,
`entities` never choosing, `version` parsed by both runtimes and declared by neither,
`Dispatch.with_spec`'s three-copy translation table, and a Ruby/Rust attribute-order
divergence. THREE were found by a field being UNMEASURABLE — which is why making the
gates fail on that rather than skip is load-bearing.

## Corpus members added for coverage (not examples)

`spec/parity/domains/` is a third corpus category — domains that exist ONLY to hold the
two runtimes to a shape no example declares.

- **market** — composite identity (`row.value` + `number.value`), two entities shaped
  differently (Booking joined from two paths, Inspection from one), a two-event command,
  a cross-reference, a closed set, a default, an optional argument. Runs through Heki
  AND SQLite.
- **relay** — one `Raise` announces TWO events with a policy on each, and the second
  acts on what the first creates, so ORDER decides the outcome. Two read models, two
  procedures over one stream.

## Traps that cost real time in the last session

- **`bin/parity` output is LONG and the interesting lines are at the TOP.** `tail` is
  the wrong tool; it truncated the corpus list three separate times.
- **Run the suite BEFORE `GOLDEN=rewrite`.** Regenerating first launders a regression
  into a fixture. A `with_spec` rename emptied every saga binding and the goldens
  absorbed it — caught only because the diff was UNBALANCED (81 and 66 lines of net
  deletion where a rename should be even).
- **`bin/ir` mints an era.** Iterating on a corpus bluebook leaves `data/eras/` and the
  next run refuses with shape drift. `rm -rf <domain>/data` between runs.
- **`cargo build` is not enough** — `cfg(test)` code fails separately. Run `cargo test`.
- **The shell cwd drifts into `rust/`** after any `cd rust`. Use absolute paths.
- **Assert every anchor BEFORE writing anything** in a multi-file script. A field-order
  mismatch caught one halfway and nothing was half-applied.
- **Adding an aggregate needs a `persisted_by` bind** in the `.hecksagon`, or boot
  refuses. Parsers agreeing is not the domain running.

## Named gaps — do not quietly close these by picking a runtime

- **wasm: this runtime cannot target it at all.** `fs` and rusqlite are unconditional.
  `~/Projects/hecks` ships to wasm (cfg-gated deps + a Cloudflare R2 adapter); we do
  not. Its own arc. See the `project-hecks-gap` memory.
- **`correlates_by` on a value-object argument diverges** — Ruby keys the conversation
  on the whole object, Rust on its JSON text. Neither is a scalar, and "an id is a
  scalar" is the rule the identity arc established. What a correlation key may BE is a
  language question. Recorded in `relay.bluebook`; relay correlates on the root instead.
- **`boot_projected` attaches no adapters** — hecks takes wiring as values too.
- **Reflex's exclusion is a Rust gap**, not a generator quirk: `Query` lacks the option
  fields the language declares.
- **Minting stays Ruby-only** until `bin/parity` can mint from BOTH runtimes and diff.

## Standing rules that still hold

1. **Never modify `~/Projects/hecks`** — reading it is fine and was useful; changing it
   is not.
2. **Ruby wins when the shapes differ.** The exporter converts.
3. **Zero warnings, zero failing tests.** Tests do no IO except `spec/adapters/`.
4. **Bluebook first.** If it is about bluebooks, `bluebook.bluebook` is where it goes.
5. **Don't trust green, and don't trust a filename.** Every real defect this session was
   found by measuring a diff or probing by hand — never by the suite going red.
