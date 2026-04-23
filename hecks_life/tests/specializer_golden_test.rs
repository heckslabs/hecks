// hecks_life/tests/specializer_golden_test.rs
//
// Golden test for the i51 Phase A Futamura specializer. Runs the
// :specialize_validator shell adapter (wired in specializer.hecksagon)
// and asserts output is byte-identical to the hand-written
// hecks_life/src/validator.rs.
//
// When this test goes green, we have the FIRST-FUTAMURA PROOF: a
// specialized interpreter (bluebook → Rust) that produces the same
// artifact a human wrote. Per plan §4 Phase A step 3, §11 key-files.
//
// If validator.rs is edited by hand, this test fails until the
// shape + specializer are updated to match. By design — every change
// to validator.rs must be reachable from validator_shape.fixtures.

use hecks_life::hecksagon_parser;
use std::fs;
use std::process::Command;

fn repo_root() -> std::path::PathBuf {
    // This test runs from hecks_life/; the repo root is one level up.
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("hecks_life has a parent")
        .to_path_buf()
}

#[test]
fn specializer_hecksagon_wiring_is_present() {
    // Confirms the capability wiring exists and declares the shell
    // adapter by name, the memory adapter, and the SpecializeRun gate.
    let path = repo_root().join("hecks_conception/capabilities/specializer/specializer.hecksagon");
    let src = fs::read_to_string(&path)
        .expect("specializer.hecksagon not found — capability wiring missing");
    let hex = hecksagon_parser::parse(&src);

    assert_eq!(hex.name, "Specializer");
    assert_eq!(hex.persistence.as_deref(), Some("memory"));
    assert!(
        hex.shell_adapters
            .iter()
            .any(|a| a.name == "specialize_validator"),
        "specialize_validator shell adapter not declared",
    );
    assert!(
        hex.shell_adapters
            .iter()
            .any(|a| a.name == "specialize_validator_warnings"),
        "specialize_validator_warnings shell adapter not declared",
    );
    assert!(
        hex.gates.iter().any(|g| g.aggregate == "SpecializeRun"),
        "SpecializeRun gate not declared",
    );
}

#[test]
fn specializer_produces_byte_identical_validator_warnings_rs() {
    // Same byte-identity gate as validator.rs, for validator_warnings.rs.
    // Phase B commit 2 target — the sibling Futamura proof.
    let root = repo_root();
    let bin = root.join("bin/specialize-validator-warnings");
    assert!(
        bin.exists(),
        "bin/specialize-validator-warnings missing — Phase B adapter unimplemented",
    );

    let output = Command::new(&bin)
        .current_dir(&root)
        .output()
        .expect("failed to invoke bin/specialize-validator-warnings");
    assert!(
        output.status.success(),
        "specializer exited non-zero:\nstderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );

    let generated = String::from_utf8(output.stdout).expect("specializer output not UTF-8");
    let hand_written = fs::read_to_string(root.join("hecks_life/src/validator_warnings.rs"))
        .expect("hecks_life/src/validator_warnings.rs missing");

    assert_eq!(
        generated.len(),
        hand_written.len(),
        "size mismatch: generated={} hand-written={}",
        generated.len(),
        hand_written.len(),
    );
    assert_eq!(
        generated, hand_written,
        "content mismatch — run `bin/specialize-validator-warnings --diff` to inspect",
    );
}

#[test]
fn specializer_produces_byte_identical_validator_rs() {
    // Run bin/specialize-validator (the Phase A implementation behind
    // the shell adapter) and compare to hand-written validator.rs.
    let root = repo_root();
    let bin = root.join("bin/specialize-validator");
    assert!(
        bin.exists(),
        "bin/specialize-validator missing — specializer adapter unimplemented",
    );

    let output = Command::new(&bin)
        .current_dir(&root)
        .output()
        .expect("failed to invoke bin/specialize-validator");
    assert!(
        output.status.success(),
        "specializer exited non-zero:\nstderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );

    let generated = String::from_utf8(output.stdout).expect("specializer output not UTF-8");
    let hand_written = fs::read_to_string(root.join("hecks_life/src/validator.rs"))
        .expect("hecks_life/src/validator.rs missing");

    assert_eq!(
        generated.len(),
        hand_written.len(),
        "size mismatch: generated={} hand-written={}",
        generated.len(),
        hand_written.len(),
    );
    assert_eq!(
        generated, hand_written,
        "content mismatch — run `bin/specialize-validator --diff` to inspect",
    );
}
