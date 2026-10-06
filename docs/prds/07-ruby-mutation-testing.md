# PRD 07 — Mutation testing of the dispatch kernel

**Status:** Rust kernel pass done (2026-10-06): 52% then 96% kill rate after triage.
The Ruby side (`mutant` on `lib/hecks/runtime/command_interpreter.rb` and siblings) is
not started; revisit it now that the Rust-only direction is paused.

## What this measures

Mutation testing deliberately breaks source (flip a comparison, stub a function to
`Ok(())`) and checks that a test fails. A surviving mutant is either an untested branch,
a weak assertion, or behaviorally equivalent. This is distinct from the DSL's own
`append`/`remove`/`multiply`/`clamp` "mutations", which are a language construct.

## Running it (Rust)

    cd rust && cargo mutants --in-place -f src/kernel/dispatch.rs -f src/kernel/orchestrate.rs

Config: `rust/.cargo/mutants.toml` (excludes generated and exemplar code, tests `--lib`).
`--in-place` is required because `kernel/pattern.rs` `include_str!`s
`spec/corpus/fixtures/patterns.json`, which a copy of `rust/` alone lacks; run it in a
clean worktree. Not in CI: ~159 mutants took ~7 minutes. Baseline `cargo test --lib` is
169 tests, about 10s with a warm build.

## First pass: `dispatch.rs` + `orchestrate.rs`

159 mutants: 66 caught, 61 missed, 32 unviable. Kill rate 66 / 127 viable = 52%.

Where the survivors cluster:

- **Guards stubbed to `Ok(())` survive.** `enforce_invariants`, `enforce_entity_invariants`,
  `enforce_givens`, `enforce_ensures`, `admissible_transition`, and the `ElementHalf`
  equivalents can be replaced with a no-op and every Rust unit test still passes. Their
  real coverage is the Ruby conformance specs (`spec/rust_conformance*_spec.rb`), which
  cargo-mutants cannot see. This is the main finding: the kernel's refusal logic has no
  Rust-side test.
- **`persist`, `emitted`, `apply_entity_command`, `ElementHalf::apply_mutations`/`run`/
  `locate_element` stubbed out survive**, same cause.
- **`trigger_args` (about 20 mutants)** is policy argument assembly with almost no unit
  tests.
- **Counter arithmetic** (`+` to `*`/`-` on step indexes in `react_policies`,
  `deliver_saga_dispatch`, `deliver_derived_compensation`): triage as test-gap or
  equivalent per site.
- **`<` to `<=` in `aggregate_position`/`entity_position`**: likely equivalent when the
  boundary index is unreachable; confirm.

## Second pass, after triage

Tests added in `rust/src/kernel/dispatch_guard_tests.rs` and `orchestrate_guard_tests.rs`
(child modules of `dispatch.rs`/`orchestrate.rs`, so they reach the private guards). They
drive the guards through a small hand-written record and a scripted dispatch: invariants,
givens, `corrects`, transitions, ensures, save/emit, the element half, policy matching, the
reaction depth ceiling, `trigger_args` routing, and the saga legs. Lib tests went from 169
to 223.

Re-run: 159 mutants, 122 caught, 5 missed, 32 unviable. Kill rate 122 / 127 = 96%, up from
52%. The three `trigger_args` `already_routed` survivors (a projected fact literally named
`to` or `with`) were then killed by a further test, leaving two:

- `aggregate_position` and `entity_position`, `<` to `<=` (`dispatch.rs:803`, `:815`):
  equivalent. A step in `ORDER` returns before the bound is reached, and an absent step
  panics either way (index out of bounds instead of the explicit `panic!`).

## Next

1. Decide whether to widen (`json.rs`, `routing.rs`, `vocab/*_dispatch_order.rs`) and
   whether to add a pass over `rust/codegen/src/mutations.rs`, whose real tests are the
   Ruby conformance specs and would need a slow `test_tool`.
2. Ruby pass with the `mutant` gem on `command_interpreter.rb`, `entity_interpreter.rb`,
   `policy_interpreter.rb`; note the DSL/builder layer may resist `mutant`.
