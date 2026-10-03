# `hecks-codegen` is the only Rust generator — 0054b's rejection lifted

**Status:** Proposed. SUPERSEDES [0054b](0054b-the-ruby-generator-stays-primary.md)
Decision items 1, 2, 4, 5 and 6 (Ruby generator stays primary; generator work
targets `rust/project` first; "not to be re-proposed"), and re-adopts the
direction of [0054a](0054a-make-hecks-codegen-the-only-rust-generator.md) with
its migration order updated to what is on `main` now. The maintainer lifted
0054b's rejection on 2026-10-02 ("single source rust generator is back on").
Nothing is deleted by this document; the deletion is step 6 below.

## Context

0054b kept two generators producing the same Rust from the same IR:
`rust/project/*.rb` (Ruby, the default behind `hecks project_rust`) and
`rust/codegen` (`hecks-codegen`, the generator inside the Ruby-free
`hecks-build` path). It chose to pay the two-copy tax and shrink it with
vocabulary projection and parity gates.

Two things have changed since.

- **The parity groundwork 0054a ordered is done.** On `main` at `09edd549`:
  - S3: `roster`, `compliance` and `embryonaut_vendoring_demo` are in the
    pipeline parity corpora.
  - B1: `rust/codegen/src/manifest.rs` writes `manifest.json`, and
    `spec/codegen_manifest_parity_spec.rb` holds it byte-identical
    (`MANIFEST_KNOWN_GAPS = {}`).
  - B2: `hecks ask rust_coverage … codegen=rust` exists
    (`lib/hecks/rust_build/coverage.rb`) and runs in CI for five domains.
  - BUG#130's `tenant_boundary_checks` and BUG#124's keyword refusal are
    ported into `hecks-codegen`.
  - `CODEGEN_PENDING_MEMBERS = {}`: no recorded gap between the generators.

  So the work 0054a called new design is finished, and what is left is the
  default switch and the deletion.
- **The tax is still being paid.** 0054a's evidence (61 BUG# commits in seven
  weeks, 19 of the latest 40 editing `rust/project/`, `rust/codegen/` and
  `rust/src/` together) is unchanged, and a projectability sweep on 2026-10-02
  found the twin generators the largest projectable pool in the repo.

### Size (verified against `origin/main` at `09edd549`, 2026-10-02)

| Piece | Lines |
|---|---|
| `rust/project/*.rb` (20 files) | 7,089 |
| `rust/project.rb`, `rust/project_rust_pipeline.rb` | 30, 387 |
| `lib/hecks/rust_build/project_rust.rb` (Ruby handler) | 332 |
| `spec/rust_project/` | 1,362 |
| `codegen_parity_spec`, `codegen_manifest_parity_spec` | 125, 89 |
| `rust/codegen/src/*.rs` (27 files, includes inline tests) | 21,396 |
| `rust/build/src` (`hecks-build`) | 1,871 |

Retirement removes about 9k lines (7.5k generator, 1.4k specs, the parity
specs), about 3% of hand-written code. The gain is not the ratio. It is that a
generator change is made once instead of three times.

## Decision

1. **`hecks-codegen` is the only Rust generator.** `rust/project`,
   `rust/project.rb` and `rust/project_rust_pipeline.rb` are deleted. A
   Ruby-free toolchain remains a product requirement (0054), so the generator
   that stays is the one that does not need Ruby.
2. **Ruby stays the semantic oracle for the runtime.** This does not touch
   [0010](0010-ruby-is-the-reference-implementation.md): the Ruby runtime is
   the reference for behavior. What changes is only who generates the Rust
   port. Ruby executing the Rust kernel (for example through wasm) stays
   rejected.
3. **`hecks project_rust` drives `hecks-codegen`.** The Ruby handler
   (`lib/hecks/rust_build/project_rust.rb`) keeps building IR from the live
   registry (Exporter, translations, source text), serialises it, and invokes
   `hecks-codegen full`. The Ruby-free `hecks-build` path feeds the same
   codegen from `hecks-parse`. There is one generator and two IR producers,
   and they are checked against each other by the existing pipeline specs.
   `HECKS_PARSER` and `HECKS_CODEGEN` are deprecated in step 2 and removed in
   step 6.
4. **`write_if_changed.rb` (83 lines) is the one piece of `rust/project`
   with no Rust twin.** Its prune-and-track behaviour moves into the handler
   or into `hecks-build`'s `cargo_sync`/sidecars pass; it is not lost.
5. **Manifest reason strings stay frozen** (0054a item 3). They are already
   byte-identical, and `ALLOWLIST` in the coverage tool does not change.
6. **New generator features target `hecks-codegen` only, from the day this
   merges.** Pending work in 0054b item 5 (D2 dispatch-order argument
   decoding, V3 refusal-template renderers) is written once, in Rust. Fixes
   to `rust/project` between acceptance and step 6 are still two-copy changes
   gated by the parity specs.
7. **The vocabulary and parser-table projections are unaffected.**
   `lib/hecks/projections/rust_vocabulary.rb` and `parser_table.rb` are
   separate generators of `rust/src/kernel/vocab/*`, not part of
   `rust/project`.

### Migration

Each step is its own PR and needs the one before it green on `main`.

1. **This ADR merges.** Docs only.
2. **Default switch.** `project_rust.rb` shells out to `hecks-codegen full`
   (about 300–400 lines, folding in the 387-line `project_rust_pipeline.rb`
   slice) and `wasm.rb` follows. The env opt-in is deprecated. A one-line
   flag keeps the Ruby generator reachable.
3. **Wire the tail.** `mod.rs`, `Cargo.toml`, sidecars, and lineage and
   translation inputs for the codegen path (about 150 lines of glue).
4. **Re-baseline.** Regenerate `rust/src/generated/` once from
   `hecks-codegen` and run `hecks regenerate_corpus --check`. Expected diff is
   empty for every domain in `Corpus.rust_regen_order`; any non-empty diff is
   a parity bug to fix in `rust/codegen` before continuing.
5. **Swap the oracle.** Replace `codegen_parity_spec` and
   `codegen_manifest_parity_spec` with a golden check against the committed
   tree. Drop the `rspec_rust_codegen` job's parity specs and keep its
   `cargo test`. Updating required checks is a ruleset change and needs
   coordinating.
6. **Delete.** After step 5 has been green on `main` for several days:
   `rust/project/`, `rust/project.rb`, `rust/project_rust_pipeline.rb`,
   `spec/rust_project/`, and the `HECKS_PARSER`/`HECKS_CODEGEN` handling.
   Fix the dependents found in the sweep: `spec/model_check_spec.rb:241`,
   `spec/projector_seam_spec.rb:54`, `spec/gemspec_packaging_spec.rb:133`,
   `lib/hecks/hecks/adapters/rust_workspace.rb` `PACKAGED`, the CI path-gate
   regex and comments in `vocabulary.bluebook`, `rust_comment_style.rb`, and
   the PR template. `validate_name!` is rewritten against Rust-side constants.

## Generating more of the hand-written Rust

With one generator, the next lever is widening what it emits. A sweep of the
hand-written Rust (about 61k lines before tests) on 2026-10-02 sorted it into
three classes. Figures are production lines, ±15%.

| Class | Lines | Meaning |
|---|---|---|
| A: generate now | ~0.4k | Driven by existing bluebook rows. The easy table-driven pieces are already generated (`kernel/vocab/*`, `parser/src/keywords.rs`, `host/src/field_hints.rs`, `build/src/reserved_names.rs`, `kernel/{expression_operators,attribute_shapes}/mod.rs`). |
| B: generate after a DSL or vocabulary addition | ~12k | The input rows do not exist yet. |
| C: genuine logic, stays hand-written | ~33k | Evaluator and orchestration step bodies, mint/CTE, journal, auth, HTTP and session handling, the host's payments and newsletter code. |

The ceiling is therefore about a quarter of the hand-written Rust, and it
is reached by adding rows, not by writing more generator code. This confirms
0011's claim for dispatch step bodies, mint, journal and auth, and does not
hold for parsing: only the keyword table was projected, and the IR-building
half is open.

Order of work, each its own ADR or PR once its input rows are designed:

1. **Form-field resolution in `host/src/web.rs`** (~400 lines, class A).
   Emit per-command form specs into the generated sidecar, and drop the
   helpers that duplicate `ui_schema.rs`.
2. **Operator and comparator semantics** (~1k lines, B). Add a `semantics`
   expression column to the query-comparator and admitted-operator rows;
   generate `kernel/query_comparators.rs` and `kernel/expression_operators/*`.
3. **Parser per-construct builders** (~5k lines in `parser/src/parse/*`, B).
   Add a target-IR-field and builder-kind column to the Syntax rows. Start
   with the simple constructs (`policy`, `query`, `domain_port`, `lifecycle`,
   `read_model`, `value_object`, about 1k lines) and leave `entity`,
   `aggregate` and `chapter` for later.
4. **IR structs and JSON codec from the meta-domain** (~1.7k lines across
   `parser/src/{ir,canonical,emit}.rs`, B). The IR's own bluebook already
   exists; fold in the `host/src/ir.rs` accessors.
5. **Presentation validators** (~2.6k lines across `ui_schema.rs`,
   `presentation.rs`, `presentation_write.rs`, B). Needs a presentation-config
   chapter first, because the config is a runtime JSON blob today. Do this
   last.

Two smaller items are not generation. `needs` (`host/src/needs.rs` and
`kernel/needs.rs`, ~440 lines) needs a Fact row with a resolver kind. The
four hand-written JSON readers and writers (`kernel`, `build`, `lsp`,
`codegen`, `json.rs`) should be consolidated into one crate. `host/src/expr_json.rs`
(~700 lines) duplicates the kernel evaluator on purpose, to keep domains out
of Lambda binaries; that dedup is a refactor and is out of scope here.

## Consequences

- **Generator fixes are written once** after step 6. BUG#124-style drift,
  where one generator was fixed and the other wasn't, cannot happen.
- **About 9k lines and one required-check job's parity specs leave the repo.**
- **The Ruby-free build becomes the build.** `hecks-build` and `hecks-codegen`
  are exercised on every regeneration, `project_wasm` and deploy parity run,
  not only by their own specs.
- **The differential oracle changes.** After step 6 nothing compares two
  generators. Correctness of generated Rust rests on `spec/corpus/semantics`,
  `spec/rust_conformance*`, `hecks regenerate_corpus --check`, and
  `rust_coverage`, which 0054 already named as the checks that matter. Parity
  of the two *IR producers* (live registry versus `hecks-parse`) stays checked
  by the pipeline specs.
- **Coverage gap to close first.** `codegen_parity_spec` compares only
  aggregate files, `registry.rs` and `mod.rs`. `metadata.rs` and `ir.json` are
  checked for presence only, and `manifest.json` is excluded from the
  pipeline byte comparison. Step 4's empty diff covers them for committed
  domains; step 5's golden check must cover them too.

## Risks

- **Re-baselining is high blast radius.** Step 4 regenerates every committed
  domain. It is safe because the parity specs already show byte-identity, but
  the parity specs do not compare `metadata.rs` or `ir.json`, so step 4 may
  surface diffs there.
- **Rollback window.** Until step 6, reverting is a one-line default flip.
  After it, a revert of about 9k lines. Step 6 therefore waits several days
  after step 5.
- **No local cold build in CI-less review.** `rust/codegen` needs `cargo
  build` to verify; the check is `bundle exec rspec --tag io
  spec/codegen_parity_spec.rb spec/codegen_manifest_parity_spec.rb` and `cd
  rust/codegen && cargo test`.
- **Coverage of inputs outside the corpus.** Parity only compares corpus
  members. A divergence for an input no corpus member exercises survives the
  switch. That is the same blind spot 0054a found, and removing the second
  generator removes the divergence rather than catching it.
- **Reversal of two prior decisions.** 0054a was adopted, then 0054b reversed
  it, and this reverses 0054b. The recorded reason this time is that the
  groundwork is already merged and the remaining cost is about 500 lines of
  new code plus one regeneration.

## What this supersedes

- **In 0054b:** Decision items 1, 2, 4, 5 and 6, and its Consequences about
  accepting the two-copy tax. Its cancellation of B3/B4/B5 is reversed.
- **Not superseded in 0054b:** the parity fixes it kept (S3, B1, B2, BUG#130)
  and the rule that no generator change merges with the two copies
  disagreeing, which stays in force until step 6.
- **Not superseded:** 0054's premise that a Ruby-free toolchain is a product
  requirement, 0010, 0011, and 0057's auto-discovered drift check.
