//! Hecks Life — the Bluebook compiler and runtime
//!
//! Reads .bluebook files, parses them into IR, and executes them.
//! The Bluebook is DNA. This is the ribosome. The runtime is life.

pub mod parser_helpers;
pub mod parse_blocks;
pub mod parser;
pub mod ir;
pub mod runtime;
pub mod json_helpers;
pub mod server;
pub mod validator;
pub mod validator_warnings;
pub mod conceiver;
pub mod heki;
pub mod heki_query;
pub mod dump;
pub mod conceiver_common;
pub mod behaviors_ir;
pub mod behaviors_parser;
pub mod behaviors_dump;
pub mod behaviors_conceiver;
pub mod behaviors_runner;
pub mod io_validator;
pub mod lifecycle_validator;
pub mod duplicate_policy_validator;
pub mod cascade;
pub mod fixtures_ir;
pub mod fixtures_parser;
pub mod hecksagon_helpers;
pub mod hecksagon_ir;
pub mod hecksagon_parser;
pub mod run;
pub mod run_stdin_loop;
