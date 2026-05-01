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

pub mod adapter_llm;
pub mod behaviors_fixtures;
pub mod behaviors_parser;
pub mod behaviors_parser_dispatch;
pub mod behaviors_runner;
pub mod conceiver;
pub mod dispatch_query;
pub mod dump;
pub mod fixtures_parser;
pub mod hecksagon_parser;
pub mod heki_query;
pub mod parse_blocks;
pub mod parser;
pub mod repository;
pub mod run_boot;
pub mod run_statusline;
pub mod runtime;
pub mod util;
pub mod validator;
pub mod validator_checks;
pub mod validator_checks_graph;
pub mod validator_corpus;
pub mod validator_morphology;
pub mod validator_warnings;

/// Dispatch by target name. Each Rust-native specializer has one
/// match arm here and one sibling module.
pub fn emit(target: &str, repo_root: &Path) -> Result<String, Box<dyn Error>> {
    match target {
        "adapter_llm" | "driven_adapter" => adapter_llm::emit(repo_root),
        "aggregate_state" => runtime::aggregate_state::emit(repo_root),
        "behaviors_fixtures" => behaviors_fixtures::emit(repo_root),
        "behaviors_parser" => behaviors_parser::emit(repo_root),
        "behaviors_runner" => behaviors_runner::emit(repo_root),
        "conceiver_generator" => conceiver::generator::emit(repo_root),
        "discover" => run_boot::discover::emit(repo_root),
        "dispatch_query" => dispatch_query::emit(repo_root),
        "dump" => dump::emit(repo_root),
        "fixtures_parser" => fixtures_parser::emit(repo_root),
        "hecksagon_parser" => hecksagon_parser::emit(repo_root),
        "heki_query" => heki_query::emit(repo_root),
        "parse_blocks" => parse_blocks::emit(repo_root),
        "parser" => parser::emit(repo_root),
        "repository" => repository::emit(repo_root),
        "run_statusline" => run_statusline::emit(repo_root),
        "system_prompt" => run_boot::system_prompt::emit(repo_root),
        "validator" => validator::emit(repo_root),
        "validator_corpus" => validator_corpus::emit(repo_root),
        "validator_warnings" => validator_warnings::emit(repo_root),
        other => Err(format!(
            "unknown specializer target: {}. Known: adapter_llm, aggregate_state, behaviors_fixtures, behaviors_parser, behaviors_runner, conceiver_generator, discover, dispatch_query, dump, fixtures_parser, hecksagon_parser, heki_query, parse_blocks, parser, repository, run_statusline, system_prompt, validator, validator_corpus, validator_warnings",
            other
        )
        .into()),
    }
}
