# i650 — Futamura self-application drift : the specializer is not self-hosted

**status** : drift (red)
**area** : specializer / autophagy / futamura
**discovered** : 2026-05-20
**predecessor** : i51 (Futamura projections), PC-4 (memory note `project_futamura_fixed_point.md`)

## TL;DR

The 2nd Futamura projection — `specialize(specialize, interpreter) == compile` — does NOT hold today. Applying the Rust-native specializer to itself is structurally impossible : `storehouse specialize` rejects any target whose output would land under `rust/src/specializer/*.rs` because no such match arm exists in `rust/src/specializer/mod.rs::emit()`.

The byte-identity proof for self-application is therefore RED. A failing test markers this drift at `rust/tests/specializer_futamura_self_application_test.rs`, gated `#[ignore]` pointing at this card.

## What was claimed (stale)

The memory file `project_futamura_fixed_point.md` (2026-04-24) asserted :

> "PC-4 retires meta_diagnostic_validator via its own meta-shape ;
>  byte-identity = 2nd Futamura proof."

This was true under the **Ruby** specializer world : `lib/hecks_specializer/meta_diagnostic_validator.rb` was emitted by `diagnostic_validator_meta_shape` and the byte-identity check held for the meta-specializer itself, i.e. PC-4 was the fixed point.

Phase E (2026-05-12, per the header comment in `rust/tests/specializer_golden_test.rs`) **deleted all of that** : `lib/hecks_specializer/` is gone, the Ruby meta-specializers are gone, and `bin/specialize` is gone. The 2nd Futamura proof died with them.

`project_futamura_fixed_point.md` should be refreshed or retired — it describes a world that no longer exists.

## What is true today

The current specializer is Rust-native, in `rust/src/specializer/`. 42 source files implement the per-target emitters that produce byte-identical Rust under `rust/src/*.rs`. Their entrypoint is `rust/src/specializer/mod.rs::emit(target, repo_root)`, dispatching to 30 match arms.

| layer | location | count |
|------|---------|-------|
| specializer source | `rust/src/specializer/*.rs` | 42 files |
| specializer emit arms | `rust/src/specializer/mod.rs` match | 30 arms |
| arms that emit a `rust/src/specializer/*.rs` file | — | **0** |

The intersection is empty. The specializer is not self-hosted. Running `storehouse specialize specializer_mod` (or any target name pointing at one of the 42 files) returns `unknown specializer target` from the fall-through arm at `mod.rs:89-93`.

## The smallest possible repair

The cheapest foothold to make the 2nd Futamura proof recoverable :

1. **Pick `rust/src/specializer/mod.rs` as the first self-application target.**
   It's the smallest (95 lines), highest-leverage (every other emit goes through it), and structurally a sibling of `cli_dispatch` (which IS specialized today — both are "match arms + pub mod declarations" tables).

2. **Author `codegen/specializer_mod_shape/`** — a meta-shape modeled on `codegen/cli_dispatch_shape/`. Row schema :

   - `Submodule` row → emits one `pub mod <name>;` line. Fields : name, order.
   - `EmitArm` row → emits one match arm in `fn emit()`. Fields : target_name (the CLI key), aliases (comma-separated), module_path (`adapter_llm` or `runtime::aggregate_state`), order.

   Header const carries the doc comment + `use std::error::Error;` + `use std::path::Path;`.

3. **Add `"specializer_mod" => specializer_mod::emit(repo_root)`** to mod.rs's dispatch (with the customary self-referential note in the comments — same trick `cli_dispatch` uses by appearing in its own emitted table).

4. **Add a golden test** in `rust/tests/specializer_golden_test.rs` asserting byte-identity against `rust/src/specializer/mod.rs`.

5. **When green** : 2nd Futamura proof is back. Promote `rust/tests/specializer_futamura_self_application_test.rs` from `#[ignore]` to active, drop the ignore reason, and refresh the memory file.

After mod.rs, the rest of the 42 files can land one by one. The fixed point — the canonical 2nd Futamura projection — is achieved the moment ANY specializer file is byte-identical from its own meta-shape. mod.rs is the natural first because the routing IS the specializer's identity.

## Why this matters

The 2nd Futamura projection is the load-bearing claim for the specializer's architectural correctness : if `specialize(specialize) == specialize`, the specializer is a fixed point of itself, the runtime can be re-derived from the bluebook + shape corpus, and the Rust tree under `rust/src/specializer/` becomes a cache, not a source. Until the proof holds, the Rust specializer is hand-written code that happens to emit other hand-written-equivalent code ; the autophagy arc has a gap.

## Pre-push gate

`rust/tests/specializer_futamura_self_application_test.rs` ships green by being `#[ignore]`'d with a link to this card. CI sees it as a skipped test, not a red. Lift the ignore when the repair lands.

## Cross-references

- Memory : `project_futamura_fixed_point.md` (stale — flag for refresh)
- Plan : `docs/plans/i51_futamura_projections.md` (lives in old worktrees only — surface a canonical copy under hecks_conception when refreshing)
- Test scaffolding : `rust/tests/specializer_golden_test.rs` (the byte-identity harness this would join)
- Sibling shape pattern : `codegen/cli_dispatch_shape/` (the model for `specializer_mod_shape`)
