# Keep one Rust generator (proposed: `rust/project`, retire `rust/codegen`)

**Status:** Proposed — a maintainer decision, deliberately not taken by the session that wrote it.

## Context

Two generators produce the same Rust from the same IR: `rust/project/*.rb` (Ruby, ~7.4k lines, what `bin/project_rust` runs by default) and `rust/codegen` (`hecks-codegen`, ~8.2k lines of Rust, reachable only through the all-Rust opt-in `HECKS_PARSER=rust HECKS_CODEGEN=rust`). `spec/codegen_parity_spec.rb` holds their output byte-identical for every corpus member.

The migration plan's stage 10 asks whether that pair still earns its keep once the semantics corpus, not byte parity, is the oracle. The evidence from stages 7–10:

- Every generator change in those stages had to be made twice, and mirrored exactly — the absent-argument check, the typed query-argument gate, the invariant-check ordering, the update-set pre-state, the checked arithmetic, the IR facts. The second copy caught no bug of its own; the parity spec only ever failed when the second copy lagged the first.
- The Rust pipeline's justification was a Ruby-free toolchain (`hecks-parse` + `hecks-codegen`). `hecks-parse` is real and stays (parser parity is structural and still valuable). `hecks-codegen` has no consumer other than the parity spec: `bin/project_rust`, CI's drift check, and the deploy parity gate all run the Ruby generator.
- What makes the generated Rust *correct* is now `spec/corpus/semantics` (both kernels answer the same frozen expectations) plus `spec/rust_conformance*` — none of which care which generator wrote the code.

## Options

1. **Keep `rust/project`, delete `rust/codegen` and `spec/codegen_parity_spec.rb`** (recommended). One generator, one place every stage-7 decision lives, ~8k lines and one CI job less. `hecks-parse` keeps the `HECKS_PARSER=rust` half of the opt-in; the IR it emits is already byte-compared to Ruby's.
2. **Keep `rust/codegen`, delete `rust/project`.** A Ruby-free build becomes possible, but `bin/project_rust`, the deploy parity gate and every projector that reads generator internals (`bin/rust_coverage`'s manifest, `rust/project/domain_generator.rb`'s skip reasons) would need porting first — real work with no user asking for it today.
3. **Keep both** — status quo; every future generator change stays a two-copy change.

## Recommendation

Option 1, unless a Ruby-free toolchain is a product requirement. If it becomes one, option 2 is the path, and the parity spec is exactly the harness that makes the switch verifiable — so the decision is reversible only while both exist, which argues for deciding now rather than drifting.

Nothing is deleted by this document.
