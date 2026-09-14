# Make `hecks-codegen` the only Rust generator — 0054 reopened, option 2 adopted

**Status:** Decided — the maintainer reopened [0054](0054-keep-one-rust-generator.md)
and adopted its option 2. Supersedes 0054's Decision section (option 3, "keep
both") and its "no immediate driver" framing; everything else in 0054 stands,
including the reason option 1 was rejected (a Ruby-free toolchain is a
product requirement, so `hecks-codegen` is the generator that stays).
Adopts the recommended order in
[0054-option-2-scoping.md](0054-option-2-scoping.md) and settles the design
questions that document deliberately left open. Nothing is deleted by this
document; the migration it orders is migration track B (B1–B5 below), and
no B-step PR merges before this document does.

## Context

0054 kept two generators producing the same Rust from the same IR —
`rust/project/*.rb` (Ruby, what `bin/project_rust` runs by default) and
`rust/codegen` (`hecks-codegen`) — and accepted the two-copy tax on every
generator change as the price of a working Ruby-free build. It named option
2 as the direction to move "if the two-copy tax becomes worse than the
porting cost," and said that migration had "no immediate driver."

The driver now exists. Ruby/Rust parity is the dominant source of fixed
bugs, and a parity fix that touches the generator has to be written twice.

### Evidence (verified against `origin/main` at `299191ec`, 2026-09-13)

- **BUG# volume.** `git log origin/main --since=2026-07-01 --oneline | grep
  -c 'BUG#'` → **61** commits naming a BUG# in their subject; **80** name
  one anywhere in the message (`--grep='BUG#'`). `origin/main`'s first
  commit is dated 2026-07-25, so this is the whole history of the branch:
  about 7 weeks.
- **How many fixes had to be written three times.** Of the 40 most recent
  commits with a BUG# in the subject, **19** edited `rust/project/`,
  `rust/codegen/` *and* `rust/src/` in the same commit — the Ruby generator,
  the Rust generator, and the regenerated output. (Sampled with `git show
  --name-only` per commit. Sampling the 40 most recent `--grep='BUG#'`
  commits instead, which also picks up QA-tooling commits that only mention
  a bug in the body, gives **16/40**; 19 of those 40 touched `rust/project/`
  at all.) Examples: BUG#22 (`5322fa81`), BUG#28 (`f6e7f0f6`), BUG#38
  (`a9fce40d`), BUG#134 (`0b3b46b2`), BUG#135 (`20bc64a4`), BUG#136
  (`0b20c1ef`), BUG#139 (`c488fe90`), BUG#140 (`ce39a6c6`).
- **Size of the two copies.** `rust/project/` is **10,319** lines of Ruby
  (**11,105** with `rust/project.rb` and `rust/project_rust_pipeline.rb`);
  `rust/codegen/src/` is **10,780** lines of Rust. `rust/build/src/` (the
  Ruby-free orchestrator, `hecks-build`) is 2,197. Both generator copies have
  grown since 0054 counted them (~7.4k / ~8.2k).
- **The copies already lag each other.** The parity spec only compares output
  for corpus members, so a fix made in one generator for input the corpus
  doesn't cover is never caught. **BUG#124** (`b0557519`, #645) — an
  aggregate whose downcased name is a Rust keyword generates an uncompilable
  module — got its refusal only in the Ruby generator
  (`rust/project/domain_generator.rb:325`, plus `naming.rb` and two
  `spec/rust_project/` specs). No file under `rust/codegen/` changed. Today
  `hecks-codegen` uses `RUST_KEYWORDS` only to `r#`-escape *fields*
  (`rust/codegen/src/naming.rs:66-78`) and has no aggregate-name check.
  So the same bluebook is refused on the default path but reaches `cargo
  build` on the Ruby-free path. In the same 40-commit sample, 3 commits
  changed `rust/project/` without changing `rust/codegen/` (BUG#124,
  BUG#130 `65871bfe`, and `f8affa4b`).

Taken together: every few days, a fix in one generator has to be copied
exactly into the other. The parity spec catches the copies drifting only on
corpus inputs, and never catches a fix that was simply never copied. That is
the "two-copy tax outweighs the porting cost" condition 0054 named, now
observed rather than hypothetical.

## Decision

**Option 2: keep `hecks-codegen`, retire `rust/project`.** Specifically:

1. **`hecks-codegen` stays and becomes the only Rust generator.** Option 1
   remains rejected for 0054's reason.
2. **`bin/project_rust` calls `hecks-build`; there is no third
   orchestrator.** The scoping document's Finding A / item 3 listed three
   ways to give `bin/project_rust` a `hecks-codegen`-backed body: route
   through `rust/project_rust_pipeline.rb`, shell out to `hecks-build`, or
   write a new thin wrapper. The decision is `hecks-build`. It already ports
   every Ruby helper that path needs (`optional_pass.rs`, `lineage_pass.rs`,
   `sidecars.rs`, `cargo_sync.rs`), and it is the Ruby-free path 0054 exists
   to protect, so making it the default path means it is exercised on every
   regeneration instead of only by its own spec. `bin/project_rust` keeps
   its Ruby IR-building half (`bin/project_rust:122-236`) for now.
   `rust/project_rust_pipeline.rb` and the `HECKS_PARSER`/`HECKS_CODEGEN`
   opt-in become redundant and are deprecated in B3 and deleted in B5.
3. **Manifest reason strings are a frozen contract.** The `manifest.json`
   writer built for `hecks-codegen` (B1) must reproduce, byte for byte, the
   `reason` text `rust/project/domain_generator.rb`'s `manifest_entry` call
   sites write today. **`bin/rust_coverage`'s `ALLOWLIST`
   (`bin/rust_coverage:374-564`) does not change during the migration** —
   not rewritten, not widened, not made generator-agnostic. This removes the
   correctness trap the scoping document named, where loosening
   `reason_match` to keep CI green quietly drops the rule that each
   allowlist entry cites a real, documented deferral. If a reason string
   ever needs to change after B5, that is a normal allowlist edit with its
   citation re-verified, not part of this migration.
4. **Generator-side work for dispatch-order and vocabulary codegen targets
   `hecks-codegen` only.** The generated dispatch-step enums and ordering
   (`AggregateStep`/`EntityStep`, generated `decode_arguments`) and the
   generated refusal-template argument renderer are not written into
   `rust/project/*.rb`. Their kernel and Ruby-runtime halves can land
   during the migration. Their generator halves wait for B5, so that no new
   generator feature is ever written twice.
5. **Migration order** — each step is its own PR, and each needs the one
   before it green on `main`:
   - **Precondition (S3):** add `examples/roster`, and confirm
     `examples/compliance`, in `spec/codegen_parity_spec.rb`'s
     `CODEGEN_CORPUS_MEMBERS`/`WHOLE_FILE_MEMBERS` and in the two
     orchestration parity specs. Fix or file any divergence found.
   - **B1 — manifest writer.** `rust/codegen/src/manifest.rs` reproduces
     every `manifest_entry` decision with identical reason strings. A spec
     diffs both generators' `manifest.json` for every manifest-mode domain.
   - **B2 — `bin/rust_coverage --codegen=rust`.** The coverage tool runs
     against `hecks-codegen` manifests, allowlist unchanged, and returns
     0-GAP on all six CI domains while the Ruby default still runs.
   - **B3 — default switch.** `bin/project_rust` (and so `bin/project_wasm`
     and the deploy parity gate, which inherit it) defaults to `hecks-build`.
     `HECKS_PARSER`/`HECKS_CODEGEN` are deprecated. The keyword-name guard
     moves into `hecks-codegen`, which closes BUG#124's Rust-side gap.
   - **B4 — regenerate and retire the parity job.** Regenerate the committed
     `rust/src/generated/` tree once from `hecks-codegen`. Delete the
     `rspec_rust_codegen` job and its required-check wrapper; that is a
     ruleset change and needs coordinating.
   - **B5 — delete `rust/project`.** Delete `rust/project/`, `rust/project.rb`,
     `rust/project_rust_pipeline.rb`, `spec/rust_project/*` (except cases
     moved elsewhere), `spec/support/ruby_codegen_prelude.rb`, and
     `spec/codegen_parity_spec.rb`. **Only after B4 has been green on `main`
     for several days**, not just after it merges.

## Consequences

- **Generator fixes stop being doubled** once B5 lands. The three-directory
  fix pattern in the evidence above becomes a two-directory one
  (`rust/codegen/` + regenerated `rust/src/`), and bugs like BUG#124, where
  one generator was fixed and the other wasn't, can no longer happen.
- **About 11k lines of Ruby and one required CI job leave the repo** (B4/B5).
- **The Ruby-free build becomes the build.** `hecks-build` goes from a path
  exercised by its own spec to the one every regeneration, `bin/project_wasm`
  call, and deploy parity gate goes through.
- **The differential oracle changes.** After B5 nothing compares two
  generators against each other. Correctness of generated Rust rests on
  `spec/corpus/semantics`, `spec/rust_conformance*`, the codegen-drift check
  over the committed tree, and `bin/rust_coverage` — which 0054 already
  identified as the checks that matter. `spec/codegen_parity_spec.rb` is
  deleted, not ported, because it has nothing left to compare against.

## Risks

- **B1 is new design, not a port.** `manifest_entry` decisions are
  interleaved through `domain_generator.rb`. `hecks-codegen` was deliberately
  not structured to carry an accumulator (`rust/codegen/src/main.rs`'s
  `run_full` header, `rust/build/src/pipeline.rs`). Freezing the reason
  strings makes the target exact but doesn't make the work smaller.
- **Re-baselining is high-blast-radius.** B4 regenerates every committed
  domain at once. It is safe only for domains already proven byte-identical
  between the generators, which is why S3 (roster/compliance) is a
  precondition, not a follow-up.
- **The soak before B5 is the rollback window.** Until `rust/project` is
  deleted, going back is a one-line default flip. After B5 it is a revert of
  ~11k lines. B5 therefore waits for B4 to be green on `main` for several
  days.
- **Work in the interim.** Generator fixes that land before B5 are still
  two-copy changes, and the parity spec still gates them. This document
  doesn't relax that; it only stops *new* generator features (item 4) from
  being built twice.
- **The migration makes CI red for a while, not green.** If B2 cannot reach
  0-GAP with the allowlist unchanged, the fix is in B1's reason strings, not
  in the allowlist.

## What this supersedes in 0054

- **Decision (option 3, "keep both").** Replaced by option 2 above.
- **"The two-copy tax on generator changes is accepted as the cost of keeping
  a working Ruby-free build today."** Withdrawn. The Ruby-free build is kept
  by making it the only build, not by keeping a second generator.
- **"That migration is real, unscoped work with no immediate driver and is
  not decided or started by this document."** The migration is now scoped
  (0054-option-2-scoping.md), has a driver (the evidence above), and is
  decided (this document).
- **Not superseded:** 0054's rejection of option 1, its premise that a
  Ruby-free toolchain is a product requirement, and its statement that the
  semantics corpus and conformance specs — not byte parity — are what make
  the generated Rust correct.
