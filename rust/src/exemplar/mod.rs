// Compile-checked Rust for every shape rust/codegen/src/*.rs emits; exemplar.rs slices the fenced
// `// TMPL:<id> BEGIN` / `END` regions and substitutes real names for the `tmpl_` vocabulary.
//
// `tmpl_*_host` functions only give fenced fragments real types and are never called, hence
// the allow below. Built under `#[cfg(test)]` only, never into a release artifact.
#![allow(dead_code, unused_variables)]

pub mod commands;
pub mod constraints;
pub mod fielded;
pub mod json;
pub mod mutations;
pub mod queries;
pub mod reactions;
pub mod read_models;
pub mod registry;
pub mod types;
