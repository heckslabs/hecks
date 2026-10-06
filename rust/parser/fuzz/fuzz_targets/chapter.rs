//! Coverage-guided target for `parse::chapter::parse_chapter`.
//!
//! The parser is a binary crate, so this target includes its modules by path and declares them at
//! its own crate root, which is where their `crate::` references resolve.
//!
//! Run from `rust/parser` with a nightly toolchain: `cargo +nightly fuzz run chapter`.
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
    // Invalid UTF-8 never reaches the parser: the binary rejects it when it reads the file.
    let Ok(source) = std::str::from_utf8(data) else {
        return;
    };
    let files = [("fuzz.bluebook".to_string(), source.to_string())];
    // A refusal is a normal answer; only a panic or a hang is a finding.
    if let Ok(bluebook) = parse::chapter::parse_chapter("Fuzzed", &files) {
        let first = emit::write(&emit::bluebook_json(&bluebook));
        let again = parse::chapter::parse_chapter("Fuzzed", &files)
            .map(|b| emit::write(&emit::bluebook_json(&b)));
        assert_eq!(
            Ok(first),
            again.map_err(|_| ()),
            "parse is not deterministic"
        );
    }
});
