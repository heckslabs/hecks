// hecks_life/tests/specializer_golden_test.rs
//
// Golden tests for the i51 Futamura specializers. Runs bin/specialize
// with a target name and asserts the output is byte-identical to the
// hand-written (now generated) .rs file.
//
// When any test goes green, we have a Futamura proof for that module:
// a specialized interpreter (bluebook → Rust) that produces the same
// artifact a human wrote. Per plan §4 Phase A step 3, §11 key-files.
//
// If a tracked .rs is edited by hand, this test fails until the
// shape + specializer are updated to match.
//
// Driver consolidation (i51 Phase B cleanup): all three specializers
// now share a single bin/specialize driver. A target is selected via
// the first positional argument.

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

/// Run `bin/specialize <target>` and assert its stdout equals the
/// contents of <rel_path> (the tracked, generated .rs).
fn assert_byte_identical(target: &str, rel_path: &str) {
    let root = repo_root();
    let bin = root.join("bin/specialize");
    assert!(
        bin.exists(),
        "bin/specialize missing — specializer driver unimplemented",
    );

    let output = Command::new(&bin)
        .arg(target)
        .current_dir(&root)
        .output()
        .unwrap_or_else(|e| panic!("failed to invoke bin/specialize {}: {}", target, e));
    assert!(
        output.status.success(),
        "bin/specialize {} exited non-zero:\nstderr: {}",
        target,
        String::from_utf8_lossy(&output.stderr),
    );

    let generated = String::from_utf8(output.stdout).expect("specializer output not UTF-8");
    let tracked_path = root.join(rel_path);
    let tracked = fs::read_to_string(&tracked_path)
        .unwrap_or_else(|e| panic!("{} missing: {}", rel_path, e));

    assert_eq!(
        generated.len(),
        tracked.len(),
        "size mismatch for target {}: generated={} tracked={}",
        target,
        generated.len(),
        tracked.len(),
    );
    assert_eq!(
        generated, tracked,
        "content mismatch for target {} — run `bin/specialize {} --diff` to inspect",
        target, target,
    );
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
    for expected in [
        "specialize_validator",
        "specialize_validator_warnings",
        "specialize_dump",
        "specialize_duplicate_policy",
        "specialize_lifecycle",
        "specialize_hecksagon_parser",
        "specialize_fixtures_parser",
        "specialize_behaviors_parser",
        "specialize_meta_subclass",
        "specialize_meta_subclass_lifecycle",
        "specialize_meta_diagnostic_validator",
        "specialize_meta_validator_warnings",
        "specialize_meta_ruby_script",
        "specialize_meta_meta_diagnostic_validator",
        "specialize_meta_meta_validator_warnings",
        "specialize_meta_ruby_module",
    ] {
        assert!(
            hex.shell_adapters.iter().any(|a| a.name == expected),
            "{} shell adapter not declared",
            expected,
        );
    }
    assert!(
        hex.gates.iter().any(|g| g.aggregate == "SpecializeRun"),
        "SpecializeRun gate not declared",
    );
}

#[test]
fn specializer_produces_byte_identical_validator_rs() {
    assert_byte_identical("validator", "hecks_life/src/validator.rs");
}

#[test]
fn specializer_produces_byte_identical_validator_warnings_rs() {
    assert_byte_identical("validator_warnings", "hecks_life/src/validator_warnings.rs");
}

#[test]
fn specializer_produces_byte_identical_dump_rs() {
    assert_byte_identical("dump", "hecks_life/src/dump.rs");
}

#[test]
fn specializer_produces_byte_identical_duplicate_policy_validator_rs() {
    assert_byte_identical(
        "duplicate_policy",
        "hecks_life/src/duplicate_policy_validator.rs",
    );
}

#[test]
fn specializer_produces_byte_identical_lifecycle_validator_rs() {
    assert_byte_identical("lifecycle", "hecks_life/src/lifecycle_validator.rs");
}

#[test]
fn specializer_produces_byte_identical_hecksagon_parser_rs() {
    // i51 Phase B — third parser retirement after validator.rs and
    // dump.rs. LineParser + LineDispatch (templated handlers) +
    // ParserHelper (verbatim bodies for the per-character automaton in
    // join_adapter_lines and the 8-key kwarg table in
    // parse_shell_adapter). Establishes the parser-shape template for
    // behaviors_parser + fixtures_parser follow-ups.
    assert_byte_identical("hecksagon_parser", "hecks_life/src/hecksagon_parser.rs");
}

#[test]
fn specializer_produces_byte_identical_fixtures_parser_rs() {
    // i51 Phase B closer — most hostile parser target. Extends the
    // shape with parse_body_snippet (verbatim parse() body; the
    // if/else-if chain + state prelude doesn't fit hecksagon's
    // continue-per-branch template), test_block_snippet (verbatim
    // 115-line `#[cfg(test)]` block), and ParserHelper.position
    // (before_root/after_root — two helpers live above parse()).
    // Eight ParserHelper rows covering the five hostile subsystems
    // (expand_ruby_escapes, matching_close_brace, extract_schema_kwarg,
    // extract_string_escape_aware, first_top_level_comma) plus three
    // simpler helpers (parse_fixture_line, split_top_level_commas,
    // escaped_at). Closes the Phase B Rust retirement arc.
    assert_byte_identical("fixtures_parser", "hecks_life/src/fixtures_parser.rs");
}

#[test]
fn specializer_produces_byte_identical_behaviors_parser_rs() {
    // i51 Phase B — fourth parser retirement. Extends the hecksagon
    // parser-shape 3-aggregate template with an else_if loop_style,
    // three new handler_kinds (capture_quoted_into_option for Option
    // fields, push_all_quoted_onto for variadic quoted lists,
    // multiline_block_direct for helpers returning T rather than
    // Option<T>), a word/word_or_equal match_mode triad, plus an
    // inline tests_snippet carrying the in-file #[cfg(test)] module
    // verbatim. Only fixtures_parser.rs remains as an open Phase B
    // Rust target after this lands.
    assert_byte_identical("behaviors_parser", "hecks_life/src/behaviors_parser.rs");
}

#[test]
fn meta_specializer_produces_byte_identical_duplicate_policy_rb() {
    // Phase C PC-1 — the self-referential pilot. The meta-specializer
    // emits a file under lib/hecks_specializer/ — the same directory
    // that holds the code doing the emission. First 2nd-Futamura proof,
    // scoped to one subclass shell.
    assert_byte_identical(
        "meta_subclass",
        "lib/hecks_specializer/duplicate_policy.rb",
    );
}

#[test]
fn meta_specializer_produces_byte_identical_lifecycle_rb() {
    // Phase C PC-1b — extends PC-1 to the second thin-subclass shell.
    // Same shape, same template, different row. Proves the pattern
    // scales past one row.
    assert_byte_identical(
        "meta_subclass_lifecycle",
        "lib/hecks_specializer/lifecycle.rb",
    );
}

#[test]
fn meta_specializer_produces_byte_identical_diagnostic_validator_rb() {
    // Phase C PC-2 — the first full Ruby class retirement (not a thin
    // subclass). Emits lib/hecks_specializer/diagnostic_validator.rb
    // from RubyClass + RubyMethod fixture rows. Exercises module
    // nesting, include mixins, public/private sections, 9 methods
    // with per-method body snippets.
    //
    // This is also the *base class that emits all the diagnostic
    // retirements* — meaning its byte-identity is doubly important:
    // hand-edit drift here breaks every diagnostic retirement.
    assert_byte_identical(
        "meta_diagnostic_validator",
        "lib/hecks_specializer/diagnostic_validator.rb",
    );
}

#[test]
fn meta_specializer_produces_byte_identical_validator_warnings_rb() {
    // Phase C PC-2 extension — second full Ruby class retirement
    // using the same meta-shape. Adds RubyConstant rows (SHAPE +
    // TARGET_RS emit at class-body top) and register_target_name
    // (the `register :validator_warnings, ValidatorWarnings` line
    // inside module Specializer after the class close). Proves the
    // shape generalizes — one shape now covers both the base class
    // AND a self-registering specializer target.
    assert_byte_identical(
        "meta_validator_warnings",
        "lib/hecks_specializer/validator_warnings.rb",
    );
}

#[test]
fn meta_specializer_produces_byte_identical_bin_specialize() {
    // Phase C PC-3 — first retirement of a top-level Ruby script
    // under bin/. Emits bin/specialize itself from a RubyScript row:
    // shebang + doc_snippet + requires_block_snippet + body_snippet.
    //
    // This is the driver that runs every other specializer target —
    // including the one being exercised here. Byte-identity means
    // the driver can regenerate itself and the build stays idempotent.
    assert_byte_identical("meta_ruby_script", "bin/specialize");
}

#[test]
fn meta_specializer_produces_byte_identical_meta_diagnostic_validator_rb() {
    // Phase C PC-4 — THE FUTAMURA FIXED POINT. The meta-specializer
    // (MetaDiagnosticValidator) regenerates its own source file
    // byte-identical from RubyClass + RubyMethod + RubyConstant rows
    // in the very fixtures it reads. When this test goes green, we
    // have a closed-form 2nd Futamura projection: a specialized
    // interpreter reproducing itself from its own shape.
    //
    // Exercises two new shape features added in PC-4:
    //   - RubyMethod.receiver ("instance"|"self") for `def self.foo`
    //   - RubyMethod.doc_snippet for inline pre-method API comments
    //   - RubyClass.requires for `require_relative` lines (used by
    //     the companion meta_validator_warnings.rb retirement below)
    assert_byte_identical(
        "meta_meta_diagnostic_validator",
        "lib/hecks_specializer/meta_diagnostic_validator.rb",
    );
}

#[test]
fn meta_specializer_produces_byte_identical_meta_validator_warnings_rb() {
    // Phase C PC-4 companion — regenerates the thin subclass file
    // meta_validator_warnings.rb from its own RubyClass + RubyMethod
    // rows. Exercises RubyClass.requires (the `require_relative
    // "meta_diagnostic_validator"` line between doc and module open)
    // alongside receiver=self for the lone `def self.target_class_name`
    // method.
    assert_byte_identical(
        "meta_meta_validator_warnings",
        "lib/hecks_specializer/meta_validator_warnings.rb",
    );
}

#[test]
fn rust_specializer_produces_byte_identical_validator_warnings_rs() {
    // Phase D pilot — hecks-life specialize (Rust-native) produces
    // output byte-identical to the Ruby bin/specialize output for the
    // same target. First proof that the specializer itself can migrate
    // from Ruby to Rust while keeping byte-identity. Every subsequent
    // Phase D port adds another test with the same shape.
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
fn meta_specializer_produces_byte_identical_hecks_specializer_rb() {
    // Phase C PC-5 — retires the loader module lib/hecks_specializer.rb
    // (108 LoC) via the new RubyModule shape. This is the first shape
    // that covers a *bare module* body (not a class): module-level
    // constants, a `class << self` block, an inner `module Target`
    // mixin, and the trailing `Dir[...].each { require }` auto-load
    // loop at file scope. Closes the loop PC-3 deferred — the three
    // shape concerns (class << self, inner module, Dir[] loop) that
    // didn't fit RubyScript now have a home.
    assert_byte_identical(
        "meta_ruby_module",
        "lib/hecks_specializer.rb",
    );
}
