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
pub mod formatter;
pub mod repl;
pub mod cli;
pub mod conceiver;
pub mod heki;
pub mod lexicon;
pub mod project;
