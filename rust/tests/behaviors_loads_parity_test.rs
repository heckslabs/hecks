//! behaviors_loads_parity_test — toy i43 parse-parity fixture (Rust half)
//!
//! Parses `parity/behaviors/loads_parse_smoke.behaviors` and asserts
//! that suite.loads and test.events_include match the values declared in
//! the file. The Ruby half lives in
//! `spec/hecks/dsl/loads_parse_smoke_parity_spec.rb` — together they
//! prove both parsers produce equivalent IR for the new i43 DSL forms.
//!
//! No runtime consumer yet (commits 3-5 are parser-only). When the
//! merge-domain runner lands (commit 6 of the plan), this fixture
//! gains a sibling `.bluebook` and joins the full behaviors parity
//! suite.

use std::fs;
use std::path::PathBuf;

fn fixture_path() -> PathBuf {
    // Cargo runs tests from the storehouse crate root.
    // parity/ stayed in the hecks tree ; resolve via the sibling hecks root.
    let hecks = std::env::var("HECKS_CONCEPTION_DIR")
        .ok()
        .and_then(|c| std::path::Path::new(&c).parent().map(|p| p.to_path_buf()))
        .unwrap_or_else(|| {
            let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
            let in_tree = manifest.join("..");
            if in_tree.join("hecks_conception").is_dir() { in_tree } else { manifest.join("../../hecks") }
        });
    hecks.join("parity/behaviors/loads_parse_smoke.behaviors")
}

#[test]
fn rust_parser_records_loads_and_then_events_include() {
    let src = fs::read_to_string(fixture_path())
        .expect("read loads_parse_smoke.behaviors");
    let suite = storehouse::behaviors_parser::parse(&src);

    assert_eq!(suite.name, "LoadsParseSmoke");
    assert_eq!(suite.loads, vec!["foo".to_string()]);
    assert_eq!(suite.tests.len(), 1);
    assert_eq!(
        suite.tests[0].events_include,
        vec!["Bar".to_string()],
        "Rust parser must populate test.events_include from then_events_include"
    );
}
