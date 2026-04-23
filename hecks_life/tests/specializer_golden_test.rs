// hecks_life/tests/specializer_golden_test.rs
//
// Golden tests for the i51 Futamura specializers. Phase E deleted the
// Ruby `bin/specialize` driver + Ruby specializer modules; the Rust-
// native `hecks-life specialize <target>` subcommand is now the only
// path. These tests invoke it and assert byte-identity against the
// tracked, generated `.rs` sources under `hecks_life/src/`.
//
// When any test goes green, we have a Futamura proof for that module:
// a specialized interpreter (bluebook → Rust) that produces the same
// artifact a human wrote.
//
// If a tracked .rs is edited by hand, this test fails until the
// shape + specializer are updated to match.

use hecks_life::hecksagon_parser;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("hecks_life has a parent")
        .to_path_buf()
}

#[test]
fn specializer_hecksagon_wiring_is_present() {
    // Confirms the capability wiring exists and declares the memory
    // adapter, all three shell adapters, and the SpecializeRun gate.
    let path = repo_root().join("hecks_conception/capabilities/specializer/specializer.hecksagon");
    let src = fs::read_to_string(&path)
        .expect("specializer.hecksagon not found — capability wiring missing");
    let hex = hecksagon_parser::parse(&src);

    assert_eq!(hex.name, "Specializer");
    assert_eq!(hex.persistence.as_deref(), Some("memory"));
    // Phase E removed all shell adapters — `hecks-life specialize`
    // (a Rust subcommand) is now the sole codegen path. The hecksagon
    // file keeps the `:memory` + `:fs` adapters + the SpecializeRun
    // gate as declarative metadata.
    assert!(
        hex.gates.iter().any(|g| g.aggregate == "SpecializeRun"),
        "SpecializeRun gate not declared",
    );
}

// Ruby-path tests deleted in Phase E PR 1 — `bin/specialize` no longer
// exists; the Rust-native `hecks-life specialize` path (below) is the
// sole gate for every target now.

#[test]
fn rust_specializer_produces_byte_identical_validator_warnings_rs() {
    // Phase D pilot — hecks-life specialize (Rust-native) produces
    // output byte-identical to the tracked .rs file. First proof that
    // the specializer itself could migrate from Ruby to Rust while
    // keeping byte-identity; Phase E subsequently deleted the Ruby
    // side. Every subsequent Phase D port added another test with the
    // same shape.
    let root = repo_root();
    let bin = root.join("hecks_life/target/release/hecks-life");
    assert!(
        bin.exists(),
        "hecks-life binary missing — build release first",
    );
    let output = Command::new(&bin)
        .args(["specialize", "validator_warnings"])
        .current_dir(&root)
        .output()
        .expect("hecks-life specialize failed");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("hecks_life/src/validator_warnings.rs"))
        .expect("validator_warnings.rs missing");
    assert_eq!(
        generated, tracked,
        "Rust specializer output drifted from tracked file",
    );
}

#[test]
fn rust_specializer_produces_byte_identical_dump_rs() {
    // Phase D D2 — second Rust-native specializer. Stretches the
    // D1 pilot to multi-aggregate dispatch, order sorting, and the
    // padded enum_match emitter. Every subsequent Rust-emitting
    // specializer (validator, the parsers) reuses this vocabulary.
    let root = repo_root();
    let bin = root.join("hecks_life/target/release/hecks-life");
    assert!(
        bin.exists(),
        "hecks-life binary missing — build release first",
    );
    let output = Command::new(&bin)
        .args(["specialize", "dump"])
        .current_dir(&root)
        .output()
        .expect("hecks-life specialize dump failed");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("hecks_life/src/dump.rs"))
        .expect("dump.rs missing");
    assert_eq!(
        generated, tracked,
        "Rust specializer output drifted from tracked file",
    );
}

// [antibody-exempt: hecks_life/tests/specializer_golden_test.rs — golden-test scaffolding]
#[test]
fn rust_specializer_produces_byte_identical_hecksagon_parser_rs() {
    // Phase D — Rust-native specializer for hecksagon_parser. Third
    // parser port in the Phase D LineParser/LineDispatch/ParserHelper
    // arc (validator, behaviors_parser, fixtures_parser). The 4-row
    // dispatch exercises capture_quoted_into, push_quoted_onto,
    // multiline_block, and multiline_adapter handler kinds against the
    // simplest single-parse-loop shape.
    let root = repo_root();
    let bin = root.join("hecks_life/target/release/hecks-life");
    assert!(
        bin.exists(),
        "hecks-life binary missing — build release first",
    );
    let output = Command::new(&bin)
        .args(["specialize", "hecksagon_parser"])
        .current_dir(&root)
        .output()
        .expect("hecks-life specialize hecksagon_parser failed");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("hecks_life/src/hecksagon_parser.rs"))
        .expect("hecksagon_parser.rs missing");
    assert_eq!(
        generated, tracked,
        "Rust specializer output drifted from tracked file",
    );
}

// [antibody-exempt: hecks_life/tests/specializer_golden_test.rs — golden-test scaffolding]
#[test]
fn rust_specializer_produces_byte_identical_validator_rs() {
    // Phase D — Rust-native specializer for validator.rs. Largest
    // standalone specializer in the codebase (393 LoC Ruby). Seven
    // check_kind emitters (unique, non_empty, first_word_verb,
    // reference_valid, trigger_valid, unique_across, distinct_aliases)
    // plus the command_naming_support block with hand-formatted suffix
    // tables, verb-exception list, and verb-suffix list. No .rs.frag
    // snippets — all emission is inline Rust format! strings.
    let root = repo_root();
    let bin = root.join("hecks_life/target/release/hecks-life");
    assert!(
        bin.exists(),
        "hecks-life binary missing — build release first",
    );
    let output = Command::new(&bin)
        .args(["specialize", "validator"])
        .current_dir(&root)
        .output()
        .expect("hecks-life specialize validator failed");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("hecks_life/src/validator.rs"))
        .expect("validator.rs missing");
    assert_eq!(
        generated, tracked,
        "Rust specializer output drifted from tracked file",
    );
}

#[test]
fn rust_specializer_produces_byte_identical_behaviors_parser_rs() {
    // Phase D — Rust-native specializer for behaviors_parser. Ports
    // the LineParser + LineDispatch + ParserHelper 3-aggregate shape
    // including the else_if loop style, tests_snippet, and the new
    // capture_quoted_into_option / push_all_quoted_onto /
    // multiline_block_direct handler kinds.
    let root = repo_root();
    let bin = root.join("hecks_life/target/release/hecks-life");
    assert!(
        bin.exists(),
        "hecks-life binary missing — build release first",
    );
    let output = Command::new(&bin)
        .args(["specialize", "behaviors_parser"])
        .current_dir(&root)
        .output()
        .expect("hecks-life specialize behaviors_parser failed");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("hecks_life/src/behaviors_parser.rs"))
        .expect("behaviors_parser.rs missing");
    assert_eq!(
        generated, tracked,
        "Rust specializer output drifted from tracked file",
    );
}

#[test]
fn rust_specializer_produces_byte_identical_fixtures_parser_rs() {
    // Phase D — Rust-native specializer for fixtures_parser. Ports the
    // smallest Rust-emitter Ruby specializer (~112 LoC) reusing the
    // LineParser + ParserHelper 2-aggregate shape (LineDispatch rows
    // are documentation-only; parse_body_snippet is authoritative).
    // Notable override: several helper bodies legitimately start with
    // `//` comments (e.g., extract_schema_kwarg's `// Find the first
    // top-level comma …`), so the port uses a bare file read instead
    // of util::read_snippet_body's leading-comment strip.
    let root = repo_root();
    let bin = root.join("hecks_life/target/release/hecks-life");
    assert!(
        bin.exists(),
        "hecks-life binary missing — build release first",
    );
    let output = Command::new(&bin)
        .args(["specialize", "fixtures_parser"])
        .current_dir(&root)
        .output()
        .expect("hecks-life specialize fixtures_parser failed");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("hecks_life/src/fixtures_parser.rs"))
        .expect("fixtures_parser.rs missing");
    assert_eq!(
        generated, tracked,
        "Rust specializer output drifted from tracked file",
    );
}

// Phase E pruned all Ruby-target golden tests. The meta-specializers
// that emitted Ruby files (meta_subclass, meta_diagnostic_validator,
// meta_ruby_script, meta_ruby_module) are deleted alongside their
// target files. Bluebook + fixtures + snippets survive as historical
// data per the Phase E plan.
