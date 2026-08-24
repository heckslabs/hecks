# Doctested guides, generated DSL reference, and a generated README

**Status: built.** Landed 2026-08-04 — the doctest harness
(`spec/support/doctest.rb`, `spec/guides_spec.rb`), all twelve guides plus
`AUTHORING.md` and `index.md` under `docs/implemented/guides/`, the generated reference
(`bin/reference`, `lib/hecks/doc/reference.rb`, `docs/implemented/reference/`,
golden-checked and coverage-gated by `spec/reference_golden_spec.rb`), and
README's own generated regions (guides index, reference pointer, corpus
roster, tool table). This file is kept as the design record — the plan below
is what was actually built, not a forward-looking proposal anymore.

## Context

hecks has excellent *maintainer* documentation (narrated code comments) and
almost nothing for the person *writing a bluebook*: README teaches ~6 of ~25
constructs, `entity`/`one_of`/`lifecycle`/`process_manager`/`ensures`/`pattern:`/
`admits:`/ports/`.world`/all translation rules and 15 of 19 bin tools have ZERO
consumer documentation, and the repo's only two consumer-ish docs
(docs/query-dsl.md, docs/event-storming-policies.md) are investigation records.
The README's Try-it snippet has silently rotted twice.

The fix follows the project's own thesis — "a declaration nothing reads cannot
disagree with anything":
1. **Doctested guides** — Markdown whose fenced examples are extracted and BOOTED
   against the real runtime by a spec; `# =>` result claims asserted; a lying
   guide goes red in CI.
2. **Generated DSL reference** — committed Markdown projected from the language's
   self-describing meta-domain (Syntax chapter Keyword/Argument rows), golden-
   checked; hand prose survives regeneration; an undocumented admitted word fails
   the suite.
3. **Comprehensive README, auto-generated where possible** — generated regions
   (guide index, reference index, bin-tool table, corpus roster with visions)
   inside hand prose, same marker mechanism; the Try-it snippet doctested.

User decisions (asked & answered): generated Markdown over YARD toolchain;
inline `# =>` assertion convention; full guide set this pass.

## Architecture

### A. Doctest harness — `spec/support/doctest.rb` (~280 loc) + `spec/guides_spec.rb` (~60 loc)

- Walks `docs/implemented/guides/*.md` **and README.md**; one `it` per file, one shared
  session per guide, per-block eval (NOT one assembled string).
- Fence info-strings: ` ```bluebook ` = declaration block (boot phase);
  ` ```ruby boot ` = wiring block (hecksagon/persisted_by, still inside
  with_registry); ` ```ruby ` = usage block (after bind_runtime); ` ```ruby skip `
  = display-only. Guide-level pragma `<!-- doctest: postgres -->` gates the whole
  file on Postgres reachability (probe + `skip` exactly as
  spec/adapters/driven/postgres_spec.rb does; scratch DB named from the guide
  filename, dropped after).
- Boot phase mirrors `spec/spec_helper.rb#boot_in_memory`: fresh Registry,
  `with_registry` → Kernel.load ports/adapters → each bluebook block written to
  its OWN Tempfile (`.bluebook` suffix; distinct paths defeat the Prism TREES
  per-path memo in lib/hecks/adapters/driven/prism.rb; keep Tempfile refs
  until after `registry.verify!`) → `Kernel.eval(src, TOPLEVEL_BINDING,
  tmp.path, 1)` (TOPLEVEL_BINDING required for ConstShim) → `ruby boot` blocks →
  `verify!` + `Runtime::Loader.bind_runtime`.
- Usage blocks eval in one per-guide shared binding with
  `eval(code, binding, guide_path, fence_line + 1)` so locals persist across
  blocks and backtraces carry real .md line numbers.
- `# => expected`: transformer buffers statements until a line ends in the marker
  AND the buffer parses cleanly (Prism check → multi-line expressions work), then
  emits `__dt__.check(line) { (expr) }.expects("expected")` — expected text is
  evaluated in the same binding, compared with `==`. Authoring convention:
  assert on `.to_h`/scalar readers, never raw Value inspect, never ids/timestamps.
- Refusal convention (refusals are half the language): `# ~> GivenNotMet: still
  be available` — wraps in begin/rescue, asserts demodulized class + message
  substring; not raising fails.
- Failure UX: `Doctest::Mismatch` naming `guide.md:LINE`, expr, expected, actual.
- Isolation: facade constants leak by design (nothing uninstalls) → harness scans
  declared chapter names and FAILS LOUDLY on cross-guide collisions (random spec
  order would make silent rebinds flaky). Each guide uses unique domain names.

### B. Reference generator — `lib/hecks/doc/reference.rb` (~230 loc) + `bin/reference` (~30 loc) + `spec/reference_golden_spec.rb` (~70 loc)

- Source: `MetaValidator.grammar_registry` → bluebook("Bluebook") → Syntax
  aggregate → Keyword rows (word, context, body, inner, opens, fills, status,
  was) + Argument rows (at, named, kind, required, fills, selects, pairs_*) —
  read exactly as `spec/syntax_conformance_spec.rb#rows` does.
- Output: `docs/implemented/reference/<context>.md` (one page per context: aggregate,
  command, query, value_object, …) + `index.md`. Per word: `## word` heading,
  generated region between `<!-- generated:begin word=X -->`/`<!-- generated:end -->`
  (signature, argument table, opens/fills, status, was:), hand prose after.
- Regeneration: parse existing page, harvest prose by word heading, re-emit in
  Keyword-row order; new words get a `<!-- TODO: document -->` sentinel; prose
  for a word no longer in the rows = HARD ERROR listing orphans.
- Golden spec: render in-memory, byte-compare whole committed files;
  `GOLDEN=rewrite` regenerates (spec/ir_golden_spec.rb precedent). Message:
  "the language and docs/implemented/reference/X disagree — run bin/reference, review the diff."
- Coverage gate in the same spec: every live (admitted/deprecated) Keyword must
  have non-sentinel prose — a new word cannot ship undocumented.

### C. README — generated regions + doctested snippet

- Same marker mechanism as reference pages; `bin/reference` (or a sibling
  `bin/readme` entry in the same lib module) regenerates: guide index (titles
  from docs/implemented/guides/*.md), reference index (contexts), bin/ tool table (first
  header-comment line of each of the 19 scripts — six currently have NO header
  comment: add one-liners to console, canonicalise, ir, project, stores,
  history), corpus roster (examples/* name + vision read from each bluebook).
- Hand sections keep: thesis, folder convention, eras narrative, single-runtime
  record. Try-it section becomes doctested blocks via harness (README walked by
  guides_spec).
- Golden-checked with the reference pages.

## Guides to write — docs/implemented/guides/ (all doctested unless noted)

1. `getting-started.md` — first bluebook, Memory boot, the door, bin/console
2. `aggregates-and-value-objects.md` — identified_by (incl. composite),
   attribute (default:/optional:/pattern:/admits:), value_object, invariant,
   one_of/member (incl. the nested-VO inline-one_of trap), list_of, references
   (reference_to/as:, has_one/belongs_to/has_many)
3. `commands.md` — role/goal, given, ensures (DbC), then_set
   (to:/append:/increment:/decrement:), emits, refusals-as-half-the-language
4. `queries-and-read-models.md` — query + the seal's rules (bare fields, numeric
   ordered comparators, declared :symbol args), option vocabulary, read_model
   reference_to/include (absorb docs/query-dsl.md's factual half)
5. `lifecycles.md` — lifecycle/transition, terminal states, what model_check flags
6. `entities.md` — entity, own commands/queries/lifecycle, addressing
7. `policies-and-process-managers.md` — policy on/trigger/across; PM
   correlates_by (dotted-scalar rule)/starts_on/ends_on/state/on…transition:/
   dispatch with:/compensation (absorb event-storming doc's mapping table)
8. `wiring.md` — .hecksagon (persisted_by, subscribe, port/operation),
   .world (realm, adapter fields/secret), Hecks.port/adapter, driving adapters
   (mock_stripe pattern), folder convention
9. `schema-evolution.md` — the pizzas era-2 story end to end: drift →
   bin/scaffold_translation → ALL SEVEN rule kinds with worked examples
   (rename/move/convert/drop/retype/compute/retired — restoring the deleted
   lineage example's teaching job) → bin/translation_audit → mint → verify.
   `<!-- doctest: postgres -->`, scratch DB.
10. `verification.md` — bin/model_check findings, bin/fuzz properties, corpus
    scripts + bin/run, the golden IR discipline
Plus `docs/implemented/guides/AUTHORING.md` (not doctested): harness conventions for future
guide writers — unique domain names, to_h assertions, `# ~>`, skip, postgres pragma.

Existing docs/ files stay as design records (rails-integration, rust-experiment);
query-dsl.md and event-storming-policies.md get a one-line pointer to their
superseding guides added at top.

## Implementation order

1. Harness (`spec/support/doctest.rb`, `spec/guides_spec.rb`) + deliberate-failure
   check of line mapping.
2. Seed guide (`getting-started.md`) proves the harness end to end.
3. Reference generator + `bin/reference` + golden spec; generate skeletons;
   verify idempotency (run twice → zero diff).
4. Guides 2–8, 10 written in parallel (agents, each given AUTHORING.md + the
   harness conventions + unique domain-name assignments); guide 9 (evolution,
   Postgres) written carefully solo.
5. Reference prose to coverage-gate green (parallel with 4).
6. README rebuild: hand sections + generated regions + doctested Try-it;
   add missing bin/ header one-liners.
7. Full suite ×2 seeds + bin/model_check; commit (logical pieces: harness,
   reference infra, guides, README) and push.

## Verification

- `bundle exec rspec spec/guides_spec.rb` — every guide green, incl. README;
  temporarily break one `# =>` to confirm failure names guide.md:line.
- `bundle exec rspec spec/reference_golden_spec.rb` — golden + coverage gate;
  edit syntax.bluebook status in a scratch check? NO — instead verify by running
  bin/reference twice (idempotent) and by the TODO-sentinel path (a word with
  sentinel prose must fail the gate before prose is written).
- Postgres guide: run with Postgres up (executes) and confirm clean skip message
  when HECKS unreachable is simulated impossible locally — rely on the spec's
  probe pattern.
- Full suite ×2 seeds, bin/model_check, push through the pre-push hook.

## Risks

- Facade constant leakage across guides → unique-name gate in harness (hard fail).
- Prism TREES memo serves stale source on path reuse → one Tempfile per block.
- Guide agents producing colliding domain names → assign name prefixes per guide
  in their briefs.
- Line-number off-by-one in eval mapping → the deliberate-failure check in step 1.
- grammar_registry boot cost — memoised once per process; negligible.
