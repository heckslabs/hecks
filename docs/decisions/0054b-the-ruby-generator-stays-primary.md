# The Ruby generator stays primary — 0054a's direction reversed, its parity fixes kept

**Status:** Accepted (maintainer decision, 2026-09-14). SUPERSEDES
[0054a](0054a-make-hecks-codegen-the-only-rust-generator.md) in full, as a
direction: `hecks-codegen` does not become the only Rust generator, and
`rust/project` is not retired. Restores
[0054](0054-keep-one-rust-generator.md)'s stance that the Ruby generator is
the default producer of the Rust port and `hecks-codegen` is kept for the
Ruby-free build. Keeps the parity fixes 0054a's migration produced (S3, B1,
B2, the BUG#130 cross-tenant port) and cancels the steps that would have
demoted or removed the Ruby generator (B3, B4, B5). Nothing is deleted by
this document.

## Context

0054 kept two generators producing the same Rust from the same IR:
`rust/project/*.rb` (Ruby, driven by `bin/project_rust`) and `rust/codegen`
(`hecks-codegen`, the generator inside the Ruby-free `hecks-build` path).
0054a reopened that decision and adopted option 2: make `hecks-codegen` the
only generator, make `hecks-build` `bin/project_rust`'s default (B3),
retire the Ruby-vs-Rust generator parity job (B4), and delete `rust/project`
(B5).

0054a's evidence was real, and it still stands (see
[0054a's Evidence section](0054a-make-hecks-codegen-the-only-rust-generator.md#evidence-verified-against-originmain-at-299191ec-2026-09-13)):

- 61 commits naming a BUG# in their subject since `origin/main` began on
  2026-07-25.
- 19 of the 40 most recent of those fixes edited `rust/project/`,
  `rust/codegen/` *and* `rust/src/` in the same commit.
- The two generator copies already lag each other on input the parity
  corpus doesn't cover (BUG#124's aggregate-keyword refusal landed only in
  the Ruby generator).

What changed is not the evidence but the answer to it. Asked directly, the
maintainer chose to keep Ruby as the oracle in both senses, and to pay down
the two-copy tax by generating more of the generators' shared tables and by
gating parity, rather than by removing the Ruby generator.

### Where the migration stood when this was decided

- **On `main`:** S3 (roster + compliance in the pipeline parity corpora,
  #669). The vocabulary-projection work that removes hand-mirrored tables
  from both generators: V1 (#670), V2 (#676), D1 (#682). 0054a itself
  (#668).
- **In the #675 stack, not yet on `main`:** B1 (`hecks-codegen` writes
  `manifest.json`, #675), B2 (BUG#32's `remove` op ported,
  `bin/rust_coverage --codegen=rust`, #680), the BUG#130 cross-tenant
  `tenant_boundary_checks` port into `hecks-codegen`, B3 (#683), and B4
  (#686). B3 and B4 merged into #675's branch, not into `main`, and are
  being reverted there before #675 merges.
- **Open:** S4 (Rust reserved names declared once, as vocabulary, #673),
  with S5 (#681) stacked on it.

## Decision

1. **Ruby remains the oracle.** The Ruby runtime is the semantic oracle for
   every other implementation, as
   [0010](0010-ruby-is-the-reference-implementation.md) says. The Ruby
   generator (`rust/project`, driven by `bin/project_rust`) stays the
   default and primary producer of the Rust port.
2. **`hecks-codegen` is kept for the Ruby-free build, held to the Ruby
   generator by parity gates.** 0054's premise that a Ruby-free toolchain is
   a product requirement still stands, so `rust/codegen` and `rust/build`
   stay. `hecks-codegen` never replaces the Ruby generator. It is held
   byte-identical to it by:
   - `spec/codegen_parity_spec.rb`
   - `spec/codegen_manifest_parity_spec.rb`
   - `spec/project_rust_pipeline_spec.rb`
   - `spec/hecks_build_pipeline_spec.rb`
   - `bin/rust_coverage --codegen=rust`

   These stay required gates, not opt-in checks.
3. **Kept from 0054a's migration**, because each one is a parity fix that
   makes `hecks-codegen` agree with the Ruby generator:
   - **S3.** Parity-corpus expansion (roster, compliance).
   - **B1.** `hecks-codegen` writes `manifest.json` byte-identical to the
     Ruby generator's, reason strings included.
   - **B2.** The `remove` mutation op ported into `hecks-codegen`, and the
     `bin/rust_coverage --codegen=rust` gate.
   - **The BUG#130 cross-tenant check** ported into `hecks-codegen`.
4. **Cancelled from 0054a's migration:**
   - **B3.** `hecks-build` does not become `bin/project_rust`'s default.
     `bin/project_rust` keeps generating through `rust/project`, and the
     `HECKS_PARSER=rust HECKS_CODEGEN=rust` opt-in stays the way to reach
     the Rust-native path.
   - **B4.** The parity specs are not demoted to opt-in, and the committed
     `rust/src/generated/` tree is not re-baselined from `hecks-codegen`.
   - **B5.** `rust/project`, `rust/project.rb`,
     `rust/project_rust_pipeline.rb`, `spec/rust_project/*`,
     `spec/support/ruby_codegen_prelude.rb` and `spec/codegen_parity_spec.rb`
     are not deleted.
5. **Generator-side structural work targets `rust/project` first, with
   `hecks-codegen` brought to parity in the same change.** This reverses
   0054a's item 4. Dispatch-order argument decoding (D2) and the
   refusal-template argument renderers (V3) are written into
   `rust/project/*.rb`, and the matching `rust/codegen` change lands in the
   same PR, gated by the parity specs above. No generator change merges
   with the two copies disagreeing.
6. **Rejected, and not to be re-proposed without the maintainer:**
   - making `hecks-codegen` the only Rust generator;
   - deleting `rust/project`;
   - having Ruby execute the Rust kernel (for example through wasm). Rust
     never becomes the runtime for Ruby's semantics.

## Consequences

- **The two-copy tax is accepted again, and paid down rather than
  removed.** Generator changes stay two-copy changes. The way to shrink them
  is to move shared tables out of both generators and into generated
  vocabulary: V1, V2 and D1 are merged, and S4 is open. Hand-mirrored logic
  that can become data should become data.
- **Drift like BUG#124 is caught by gates, not by deleting a copy.** B1's
  manifest parity and B2's `--codegen=rust` coverage gate compare the two
  generators' *decisions*, not just the output of corpus members. So a fix
  made in only one generator now shows up as a manifest or coverage
  divergence even when the corpus doesn't exercise it.
- **`hecks-build` remains a secondary path**, exercised by its own pipeline
  spec and by the parity gates rather than by every regeneration. The deploy
  parity gate and `bin/project_wasm` keep inheriting `bin/project_rust`'s
  Ruby default.
- **No large deletion and no re-baseline.** The ~11k lines of Ruby generator,
  the `rspec_rust_codegen` job and its required-check wrapper all stay. The
  committed `rust/src/generated/` tree stays Ruby-generator output.
- **The differential oracle is unchanged.** Correctness of generated Rust
  still rests on `spec/corpus/semantics` and `spec/rust_conformance*`, as
  0054 said. On top of that, two generators are compared against each other,
  and the Ruby generator is the reference side of that comparison.

## What this supersedes

- **In 0054a:**
  - its Decision items 1, 2 and 4 (only generator, `hecks-build` as the
    default, generator features targeting `hecks-codegen` only);
  - migration steps B3, B4 and B5;
  - its Consequences section (no more doubled fixes, Ruby and the parity
    job leaving the repo, the Ruby-free build becoming *the* build, the
    differential oracle changing).
- **Not superseded in 0054a:**
  - its Evidence section;
  - item 3, frozen manifest reason strings with `bin/rust_coverage`'s
    `ALLOWLIST` unchanged (still how B1 is held to the Ruby generator);
  - S3, B1 and B2 as parity work.
- **In 0054:** nothing further. This document restores 0054's Decision in
  substance: keep both generators, with the Ruby generator as the default.
  What it adds is the parity gates B1 and B2 introduced, and the explicit
  rule that `hecks-codegen` is held to the Ruby generator, never the other
  way round.
