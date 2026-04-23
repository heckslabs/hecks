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
        "specialize_meta_subclass",
        "specialize_meta_subclass_lifecycle",
        "specialize_meta_diagnostic_validator",
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
