//! Coverage-guided target for `parse::chapter::resolve_hecksagon_dependencies`.
//!
//! Run from `rust/parser` with a nightly toolchain: `cargo +nightly fuzz run resolve`.
#![no_main]
#![allow(dead_code)]

#[path = "../../src/build/mod.rs"]
mod build;
#[path = "../../src/canonical.rs"]
mod canonical;
#[path = "../../src/diag.rs"]
mod diag;
#[path = "../../src/emit.rs"]
mod emit;
#[path = "../../src/expr/mod.rs"]
mod expr;
#[path = "../../src/ir.rs"]
mod ir;
#[path = "../../src/keywords.rs"]
mod keywords;
#[path = "../../src/lex.rs"]
mod lex;
#[path = "../../src/parse/mod.rs"]
mod parse;
#[path = "../../src/ruby_value.rs"]
mod ruby_value;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(source) = std::str::from_utf8(data) else {
        return;
    };
    let _ = parse::chapter::resolve_hecksagon_dependencies("Fuzzed", "fuzz.hecksagon", source);
});
