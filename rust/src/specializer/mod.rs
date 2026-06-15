//! Rust-native specializer driver — the final destination of the i51
//! Futamura arc.
//!
//! Phase E completed: the Ruby `lib/hecks_specializer/` modules, the
//! `bin/specialize` driver, and the Ruby-emitting Rust meta-specializers
//! have all been deleted. This module is now the sole codegen path for
//! every Rust target under `storehouse/src/*.rs`. Each sibling module
//! owns one target's emission logic and exposes
//! `emit(repo_root: &Path) -> Result<String, _>`.
//!
//! Golden tests in `storehouse/tests/specializer_golden_test.rs`
//! enforce byte-identity against the tracked `.rs` sources.
//!
//! Usage (from main.rs):
//!   let rust = specializer::emit("validator_warnings", &repo_root)?;
//!   print!("{}", rust);

use std::error::Error;
use std::path::Path;

pub mod adapter_llm;
pub mod assemble;
pub mod behaviors_fixtures;
pub mod behaviors_parser;
pub mod behaviors_parser_dispatch;
pub mod behaviors_runner;
pub mod cf_function_proxy;
pub mod cli_dispatch;
pub mod conceiver;
pub mod dispatch_query;
pub mod dump;
pub mod embedded_bluebooks;
pub mod fixtures_parser;
pub mod hecksagon_parser;
pub mod heki_query;
pub mod html_domain;
pub mod ir;
pub mod lifecycle_validator;
pub mod parse_blocks;
pub mod parser;
pub mod parser_helpers;
pub mod repository;
pub mod ruby_command_class;
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
pub mod wasm_worker;
pub mod wrangler_toml;

/// Dispatch by target name. Each Rust-native specializer has one
/// match arm here and one sibling module.
pub fn emit(target: &str, repo_root: &Path) -> Result<String, Box<dyn Error>> {
    match target {
        "adapter_llm" | "driven_adapter" => adapter_llm::emit(repo_root),
        "aggregate_state" => runtime::aggregate_state::emit(repo_root),
        "assemble" => assemble::emit(repo_root),
        "behaviors_fixtures" => behaviors_fixtures::emit(repo_root),
        "behaviors_parser" => behaviors_parser::emit(repo_root),
        "behaviors_runner" => behaviors_runner::emit(repo_root),
        "cli_dispatch" | "main" => cli_dispatch::emit(repo_root),
        "command_dispatch" => runtime::command_dispatch::emit(repo_root),
        "conceiver_generator" => conceiver::generator::emit(repo_root),
        "discover" => run_boot::discover::emit(repo_root),
        "dispatch_query" => dispatch_query::emit(repo_root),
        "dump" => dump::emit(repo_root),
        "fixtures_parser" => fixtures_parser::emit(repo_root),
        "hecksagon_parser" => hecksagon_parser::emit(repo_root),
        "heki_query" => heki_query::emit(repo_root),
        "html_domain" => html_domain::emit(repo_root),
        "interpreter" => runtime::interpreter::emit(repo_root),
        "ir" => ir::emit(repo_root),
        "lifecycle_validator" => lifecycle_validator::emit(repo_root),
        "parse_blocks" => parse_blocks::emit(repo_root),
        "parser" => parser::emit(repo_root),
        "event_driving" => runtime::event_driving::emit(repo_root),
        "persistence_resolution" => runtime::persistence_resolution::emit(repo_root),
        "query" => runtime::query::emit(repo_root),
        "reaction" => runtime::reaction::emit(repo_root),
        "parser_helpers" => parser_helpers::emit(repo_root),
        "repository" => repository::emit(repo_root),
        "runtime" => runtime::root::emit(repo_root),
        "run_statusline" => run_statusline::emit(repo_root),
        "system_prompt" => run_boot::system_prompt::emit(repo_root),
        "validator" => validator::emit(repo_root),
        "validator_corpus" => validator_corpus::emit(repo_root),
        "validator_warnings" => validator_warnings::emit(repo_root),
        other => Err(format!(
            "unknown specializer target: {}. Known: adapter_llm, aggregate_state, assemble, behaviors_fixtures, behaviors_parser, behaviors_runner, cli_dispatch, command_dispatch, conceiver_generator, discover, dispatch_query, dump, fixtures_parser, hecksagon_parser, heki_query, html_domain, interpreter, ir, lifecycle_validator, parse_blocks, parser, parser_helpers, repository, runtime, run_statusline, system_prompt, validator, validator_corpus, validator_warnings",
            other
        )
        .into()),
    }
}

/// Emit a single named section of a multi-section specializer target — the
/// scoped sub-target behind `storehouse specialize <target> --section
/// <name>`. Powers the per-concern byte-identity goldens the
/// runtime-as-bluebook strangler relies on (see
/// inbox/runtime-as-bluebook.md). Only `runtime` supports sections today ;
/// other targets return an error naming the limitation.
pub fn emit_section(
    target: &str,
    repo_root: &Path,
    section: &str,
) -> Result<String, Box<dyn Error>> {
    match target {
        "runtime" => runtime::root::emit_section(repo_root, section),
        other => Err(format!(
            "specializer target '{}' does not support --section (only 'runtime' does)",
            other
        )
        .into()),
    }
}
