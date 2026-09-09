# Keep one Rust generator — decided against; a Ruby-free toolchain is required

**Status:** Decided (status quo) — the maintainer confirmed a Ruby-free build
toolchain is a product requirement, so `rust/codegen` stays.

## Context

Two generators produce the same Rust from the same IR: `rust/project/*.rb`
(Ruby, ~7.4k lines, what `bin/project_rust` runs by default) and
`rust/codegen` (`hecks-codegen`, ~8.2k lines of Rust, reachable only through
the all-Rust opt-in `HECKS_PARSER=rust HECKS_CODEGEN=rust`).
`spec/codegen_parity_spec.rb` holds their output byte-identical for every
corpus member.

The migration plan's stage 10 asked whether that pair still earns its keep
once the semantics corpus, not byte parity, is the oracle. The evidence from
stages 7–10:

- Every generator change in those stages had to be made twice, and mirrored
  exactly — the absent-argument check, the typed query-argument gate, the
  invariant-check ordering, the update-set pre-state, the checked
  arithmetic, the IR facts. The second copy caught no bug of its own; the
  parity spec only ever failed when the second copy lagged the first.
- What makes the generated Rust *correct* is now `spec/corpus/semantics`
  (both kernels answer the same frozen expectations) plus
  `spec/rust_conformance*` — none of which care which generator wrote the
  code.

This document originally recommended deleting `rust/codegen` (option 1
below) on the grounds that its only stated justification — a Ruby-free
build — had no consumer other than the parity spec itself. **That premise
was wrong.** `rust/build` (`hecks-build`, the Stage 8 capstone) is a real,
already-built, compiled-Rust orchestrator whose entire purpose is compiling
a domain from `.bluebook` source to a running artifact with zero Ruby
involved anywhere in the chain — it calls `hecks-parse` and `hecks-codegen`
as subprocesses for exactly that reason, and it has its own novel logic
(`optional_pass.rs`) and its own spec (`spec/hecks_build_pipeline_spec.rb`,
via `rust/project_rust_pipeline.rb`, the Ruby-orchestrated predecessor it
ports step-for-step). Deleting `hecks-codegen` does not just remove a
redundant generator — it removes the only thing that makes a Ruby-free
build possible at all, since `rust/project` is Ruby-authored and has no
Rust-native substitute.

Asked directly, the maintainer confirmed: a Ruby-free toolchain **is** a
product requirement. That is precisely the condition this document's
original recommendation named as the reason NOT to take option 1.

## Options

1. ~~Keep `rust/project`, delete `rust/codegen` and
   `spec/codegen_parity_spec.rb`.~~ **Rejected** — would delete the only
   Ruby-free build path (`rust/build`) along with it.
2. **Keep `rust/codegen`, delete `rust/project`.** A Ruby-free build
   becomes the ONLY path, but `bin/project_rust`'s default (Ruby) path, the
   deploy parity gate, and every projector that reads generator internals
   (`bin/rust_coverage`'s manifest, `rust/project/domain_generator.rb`'s
   skip reasons) would need porting first — real work, not scoped or
   started here.
3. **Keep both — status quo.** Every future generator change stays a
   two-copy change, verified by `spec/codegen_parity_spec.rb`, in exchange
   for `rust/build`'s Ruby-free path continuing to work today.

## Decision

**Option 3.** Nothing in `rust/codegen`, `rust/build`,
`rust/project_rust_pipeline.rb`, `spec/codegen_parity_spec.rb`, or the CI
jobs that exercise them changes. The two-copy tax on generator changes is
accepted as the cost of keeping a working Ruby-free build today.

Option 2 (make `hecks-codegen` the only generator, retiring
`rust/project`) is the direction to move in if the two-copy tax becomes
worse than the porting cost — `bin/project_rust`'s Ruby path, the deploy
parity gate, and `bin/rust_coverage` would all need to move onto
`hecks-codegen`'s output first. That migration is real, unscoped work with
no immediate driver and is not decided or started by this document.

Nothing is deleted by this document.
