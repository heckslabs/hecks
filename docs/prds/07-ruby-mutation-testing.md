# PRD 07 — Mutation testing of the dispatch kernel

**Status:** First pass run on the Rust kernel (2026-10-06); survivors not yet triaged.
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

## Next

1. Triage each survivor: add a Rust test, or record it as equivalent with a one-line reason.
2. Re-run and record the new kill rate here.
3. Decide whether to widen (`json.rs`, `routing.rs`, `vocab/*_dispatch_order.rs`) and
   whether to add a pass over `rust/codegen/src/mutations.rs`, whose real tests are the
   Ruby conformance specs and would need a slow `test_tool`.
4. Ruby pass with the `mutant` gem on `command_interpreter.rb`, `entity_interpreter.rb`,
   `policy_interpreter.rb`; note the DSL/builder layer may resist `mutant`.
