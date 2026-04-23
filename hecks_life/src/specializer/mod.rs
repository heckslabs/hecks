//! Rust-native specializer driver — the destination for the i51
//! Phase D Ruby → Rust migration of `lib/hecks_specializer/`.
//!
//! Each module under `specializer::` owns one target's emission logic,
//! exposing `emit(repo_root: &Path) -> Result<String, _>`. The
//! top-level `emit(target, repo_root)` dispatcher matches a target
//! name to its module, mirroring `Hecks::Specializer.emit(:name)` on
//! the Ruby side.
//!
//! Phase D policy — both runtimes MUST produce byte-identical output
//! for every ported target until the migration completes. Golden
//! tests in `hecks_life/tests/specializer_golden_test.rs` enforce
//! this for each port.
//!
//! Usage (from main.rs):
//!   let rust = specializer::emit("validator_warnings", &repo_root)?;
//!   print!("{}", rust);

use std::error::Error;
use std::path::Path;

pub mod behaviors_parser;
pub mod behaviors_parser_dispatch;
pub mod dump;
pub mod fixtures_parser;
pub mod hecksagon_parser;
pub mod meta_diagnostic_validator;
pub mod meta_ruby_script;
pub mod util;
pub mod validator;
pub mod validator_checks;
pub mod validator_checks_graph;
pub mod validator_morphology;
pub mod validator_warnings;

/// Dispatch by target name. Phase D ports are additive — each new
/// Rust-native specializer adds one match arm here and one module
/// under `specializer::`.
pub fn emit(target: &str, repo_root: &Path) -> Result<String, Box<dyn Error>> {
    match target {
        "behaviors_parser" => behaviors_parser::emit(repo_root),
        "fixtures_parser" => fixtures_parser::emit(repo_root),
        "hecksagon_parser" => hecksagon_parser::emit(repo_root),
        "meta_diagnostic_validator" => meta_diagnostic_validator::emit(repo_root),
        "meta_ruby_script" => meta_ruby_script::emit(repo_root),
        "validator" => validator::emit(repo_root),
        "validator_warnings" => validator_warnings::emit(repo_root),
        "dump" => dump::emit(repo_root),
        other => Err(format!(
            "unknown specializer target: {}. Known: behaviors_parser, dump, fixtures_parser, hecksagon_parser, meta_diagnostic_validator, meta_ruby_script, validator, validator_warnings",
            other
        )
        .into()),
    }
}
