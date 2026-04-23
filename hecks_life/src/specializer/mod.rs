//! Rust-native specializer driver — the final destination of the i51
//! Futamura arc.
//!
//! Phase E completed: the Ruby `lib/hecks_specializer/` modules, the
//! `bin/specialize` driver, and the Ruby-emitting Rust meta-specializers
//! have all been deleted. This module is now the sole codegen path for
//! every Rust target under `hecks_life/src/*.rs`. Each sibling module
//! owns one target's emission logic and exposes
//! `emit(repo_root: &Path) -> Result<String, _>`.
//!
//! Golden tests in `hecks_life/tests/specializer_golden_test.rs`
//! enforce byte-identity against the tracked `.rs` sources.
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
pub mod util;
pub mod validator;
pub mod validator_checks;
pub mod validator_checks_graph;
pub mod validator_morphology;
pub mod validator_warnings;

/// Dispatch by target name. Each Rust-native specializer has one
/// match arm here and one sibling module.
pub fn emit(target: &str, repo_root: &Path) -> Result<String, Box<dyn Error>> {
    match target {
        "behaviors_parser" => behaviors_parser::emit(repo_root),
        "dump" => dump::emit(repo_root),
        "fixtures_parser" => fixtures_parser::emit(repo_root),
        "hecksagon_parser" => hecksagon_parser::emit(repo_root),
        "validator" => validator::emit(repo_root),
        "validator_warnings" => validator_warnings::emit(repo_root),
        other => Err(format!(
            "unknown specializer target: {}. Known: behaviors_parser, dump, fixtures_parser, hecksagon_parser, validator, validator_warnings",
            other
        )
        .into()),
    }
}
