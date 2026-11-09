# Layer the Rust build: a kernel crate, then domain crates

**Status:** Proposed. Date: 2026-11-09. Not built: this records what was measured, what the first cut of the Rust
CPU work did instead, and when the split would pay.
Relates to ADR 0012 (the kernel is std-only, named in `rust/src/lib.rs`) and
[0110](0110-a-client-downloads-the-host-hecks-already-built.md) (the prebuilt host).

## Context

A process snapshot on 2026-11-09 showed one `rustc` at 384% of a core. The `rust` crate holds about 18,000 lines of
hand-written kernel and about 261,000 lines of generated code for about 50 domains, each behind a Cargo feature
(`rust/src/generated/mod.rs`). A build compiles the kernel and the generated modules of the selected features as one
crate. The native conformance build (`NativeBuild`) pins one binary per feature, so a full sweep builds the crate
once for every domain.

Measured on this machine (12 cores, rustc 1.98.0, `nice -n 15`, one build at a time, a scratch target directory):

| Build | Wall | CPU | `rust` crate unit |
|---|---|---|---|
| cold, `--features pizzas` (plus the default `reserved_names_fixture`) | 7.64 s | 12.1 s | 4.99 s |
| same, `CARGO_INCREMENTAL=0` | 4.26 s | 7.6 s | 3.92 s |
| `--features banking`, same target directory | 8.83 s | 15.1 s | 8.58 s |
| edit one kernel file (`src/kernel/pattern.rs`), `pizzas` | 0.86 s | 0.7 s | 0.71 s |
| touch one generated file (`pizzas/merged.rs`), `pizzas` | 1.04 s | 0.8 s | 0.83 s |

- **Dependencies are shared once built.** In the cold pizzas build `regex-syntax`, `regex-automata`, `regex` and
  `hecks_expr` took 1.22, 0.95, 0.23 and 0.37 s (2.8 s of the 7.6 s). The banking build reused all four (0.0 s).
  Only the `rust` crate unit repeats per feature.
- **The crate unit scales with the code.** Counting lines, pizzas compiles about 28,500 (kernel 16,589, exemplar
  1,429, always-compiled generated code 4,576, pizzas 3,509, the default fixture 2,253) and banking about 61,800
  (banking is 36,840). A two-point fit gives about 0.11 s per thousand lines plus about 1.9 s, so the always-compiled
  part (about 22,700 lines) costs about 2.4 s of every build: about half of a pizzas crate unit, about a third of a
  banking one, and under a fifth of the meta domain's (74,450 lines). The fit rests on two points.
- **Incremental builds are cheap.** Once built, an edit to the kernel or to one generated file rebuilds in about a
  second, because the dev profile compiles incrementally. A cold build is the cost, and it is paid once per target
  directory and feature set. The incremental cache is large: cleaning the crate from a scratch directory removed
  766.7 MiB.
- **The kernel does not build alone.** `cargo build --no-default-features` fails with `E0432: unresolved import
  crate::generated::active`: `src/kernel/cli.rs` imports the dispatcher, the store and `ENTITY_QUERIES` from the
  selected domain's `active` module. A comment in `src/kernel/ir_presenter.rs` already calls moving the presenter
  "the first slice of dropping `generated::active`".
- **Registry dependencies.** The `rust` crate's only registry dependencies are the five `regex` packages through
  `hecks_expr`. `rust/parser` and `rust/codegen` have none. `rust/host` has 402 (wasmtime, tokio, axum, rustls and the
  AWS SDK); a cold host build was not measured, since it takes minutes of all cores.

Only `rust/web` depends on the `rust` crate by path. The three integration tests under `rust/tests` use it as a
library.

## What was built instead

The CPU peg is a count of builds, not the cost of one. This record's companion change (CHANGELOG, Unreleased) does
four things that do not need the split:

1. **One build at a time.** Every `cargo` or `rustc` that hecks starts runs under a `flock` on one file in the cache
   directory (`RustBuild::BuildLock`), so several agents building at once queue. `HECKS_NO_BUILD_LOCK=1` and CI skip
   it; a build started by hand is untouched.
2. **A job cap and `nice` in every checkout.** The Tickets world's `rust_build "RustBuild", jobs: 4, nice: 15` line
   (`RustBuild::BuildPolicy`) sets `CARGO_BUILD_JOBS` and `nice` for every build hecks starts, the owner's main
   checkout included. A `CARGO_BUILD_JOBS` set by hand wins.
3. **A binary another workspace built.** `RustBuild::BinaryCache` keeps each native binary under a digest of the
   sources' bytes, the compiler and the feature. A worktree whose `rust/` is unchanged takes the binary instead of
   compiling the crate (`NativeBuild#build_or_restore`). The newest 32 stay.
4. **The corpus check was already skipped when unchanged.** `regenerate_corpus --check` returns "skipped as unchanged"
   through the gate memo (`codegen_drift`), so it needed no change.

## Decision

**Do not split the kernel into its own crate now.** The split would save about 2.4 s of CPU in each feature build
once the kernel is compiled. A full conformance sweep of about 50 features is therefore worth about two CPU-minutes,
and the binary cache already removes the repeat for worktrees that did not change `rust/`. That is small next to
what the pipeline spent on launcher boots, and the split needs the entanglement undone first.

Revisit it when one of these holds:

- the kernel grows past the generated code of a typical domain, so its share of each build is the larger part;
- conformance is run for every feature on every change, so the cold feature builds are paid daily;
- `generated::active` is dropped from the kernel for its own reasons, which is the precondition below.

## What the split needs (estimate)

1. **Cut the kernel's reach into `generated::active`.** `kernel/cli.rs` would take the dispatcher, store and query
   table through a trait or a function table the domain crate registers, as the presenter already does. This is the
   bulk of the work, and `kernel_dependencies.rs` (a test of the kernel's allowed dependencies) must keep passing.
2. **Make the kernel a crate with no features.** It stays std-only (ADR 0012). `hecks_expr` stays its one dependency.
3. **Make each generated domain a thin crate on top**, or keep the feature gates in one crate that depends on the
   kernel crate. The second is the smaller step and keeps `generated/mod.rs` as it is.
4. **Teach the generator and its checks.** `project_rust` (`root_mod`) writes `generated/mod.rs` and the Cargo
   features; `NativeBuild` pins `debug/rust-<feature>`; `build.check_conformance` and the Ruby/Rust parity specs assume
   one crate. `rust/web` depends on it by path.

Effort: about a week for step 1 and a day or two for the rest, with the conformance sweep as the check that nothing
moved.

## Not done, and why

- **Sharing the host's dependencies across worktrees.** A binary build takes a per-worktree target directory
  (ADR 0201's companion fix), so each worktree that builds `rust/host` compiles its 402 registry packages again. The
  cost is real but unmeasured. Putting the host back in the shared directory is safe only if the binary is copied out
  while the build lock is held; `Host.compile` returns a path that `publish` reads later. `sccache` would share the
  packages without that change, and is not installed here.
- **A kernel-only prebuilt for macOS.** Only Linux host rows are published (ADR 0110).
