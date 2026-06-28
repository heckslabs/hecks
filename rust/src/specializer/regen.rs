//! Regenerate-all : the "edit the generator, never the .rs" reflex as one
//! command. `storehouse specialize all` walks `targets()` and rewrites every
//! byte-identity Rust target to its tracked path from the generators on disk.
//!
//! `targets()` is the SINGLE source of the target -> output-path map. Run it
//! from a STABLE (installed) binary so a mid-edit dev tree never blocks its
//! own regeneration, then `cargo build`. The specializer golden suite
//! (tests/specializer_golden_test.rs) gates each target's byte-identity ; this
//! module is the bulk-apply side of the same contract.
//!
//! TWO classes are deliberately EXCLUDED from `all` :
//!   1. Per-deployment emitters (wasm_worker / cf_function_proxy /
//!      embedded_bluebooks / wrangler_toml / procfile) — flag-driven output,
//!      not a single tracked file.
//!   2. The runtime kernel files (mod.rs + persistence_resolution / query /
//!      reaction / event_driving) are hand-written Rust — codegen/runtime_shape
//!      was retired 2026-06-27 (a .bluebook that only re-emitted imperative Rust
//!      captures no domain). cli_dispatch and run_statusline were retired the
//!      same way earlier : their shapes lost the race with hand-editing, so
//!      main.rs / run_statusline are honestly hand-maintained too.

use super::emit;
use std::error::Error;
use std::path::Path;

/// Every byte-identity Rust specializer target with a CURRENT generator
/// (passing golden) paired with its tracked output path (repo-root-relative).
/// Adding a generated target = one row here. The `runtime` whole-file target
/// is intentionally absent (runtime/mod.rs is section-maintained — see the
/// module header).
pub fn targets() -> &'static [(&'static str, &'static str)] {
    &[
        ("adapter_llm",              "rust/src/runtime/adapter_llm.rs"),
        ("aggregate_state",          "rust/src/runtime/aggregate_state.rs"),
        ("assemble",                 "rust/src/run_status/assemble.rs"),
        ("behaviors_fixtures",       "rust/src/behaviors_fixtures.rs"),
        ("behaviors_parser",         "rust/src/behaviors_parser.rs"),
        ("behaviors_runner",         "rust/src/behaviors_runner.rs"),
        ("command_dispatch",         "rust/src/runtime/command_dispatch.rs"),
        ("conceiver_generator",      "rust/src/conceiver/generator.rs"),
        ("conception_kernel_sample", "rust/src/conception_kernel/sample.rs"),
        ("discover",                 "rust/src/run_boot/discover.rs"),
        ("dispatch_query",           "rust/src/dispatch_query.rs"),
        ("dump",                     "rust/src/dump.rs"),
        ("fixtures_parser",          "rust/src/fixtures_parser.rs"),
        ("hecksagon_ir",             "rust/src/hecksagon_ir.rs"),
        ("hecksagon_parser",         "rust/src/hecksagon_parser.rs"),
        ("heki_query",               "rust/src/heki_query.rs"),
        ("html_domain",              "rust/src/server/html_domain.rs"),
        ("interpreter",              "rust/src/runtime/interpreter.rs"),
        ("ir",                       "rust/src/ir.rs"),
        ("lifecycle_validator",      "rust/src/lifecycle_validator.rs"),
        ("parse_blocks",             "rust/src/parse_blocks.rs"),
        ("parser",                   "rust/src/parser.rs"),
        ("parser_helpers",           "rust/src/parser_helpers.rs"),
        ("repository",               "rust/src/runtime/repository.rs"),
        ("specializer_mod",          "rust/src/specializer/mod.rs"),
        ("system_prompt",            "rust/src/run_boot/system_prompt.rs"),
        ("validator",                "rust/src/validator.rs"),
        ("validator_corpus",         "rust/src/validator_corpus.rs"),
        ("validator_warnings",       "rust/src/validator_warnings.rs"),
    ]
}

/// Regenerate every `targets()` entry to its tracked path from the
/// generators currently on disk. Returns the number of files written.
pub fn emit_all_to_disk(repo_root: &Path) -> Result<usize, Box<dyn Error>> {
    for (target, rel) in targets() {
        let rust = emit(target, repo_root)?;
        std::fs::write(repo_root.join(rel), &rust)
            .map_err(|e| format!("write {}: {}", rel, e))?;
    }
    Ok(targets().len())
}
