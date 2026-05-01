//! Conceiver parity test
//!
//! Asserts that `conceiver/` and `behaviors_conceiver/` stay
//! architecturally parallel. The two halves of drift prevention:
//!
//!   1. Shared infrastructure (conceiver_common.rs) — both conceivers
//!      use the same scan/nearest/similarity primitives, so drift in
//!      those is impossible by construction.
//!
//!   2. This test — asserts the per-conceiver pieces stay parallel:
//!      same module file layout, both implement the Conceiver trait,
//!      both vector functions return non-empty Vec<f64>, both can
//!      generate scaffolds end-to-end.
//!
//! When you add a file to one conceiver, this test fails until you
//! add the equivalent to the other (or update this test to accept
//! the asymmetry deliberately).

use hecks_life::behaviors_conceiver::BehaviorsConceiver;
use hecks_life::behaviors_ir::TestSuite;
use hecks_life::conceiver::BluebookConceiver;
use hecks_life::conceiver_common::Conceiver;
use hecks_life::ir::Domain;
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

const BLUEBOOK_DIR:  &str = "src/conceiver";
const BEHAVIORS_DIR: &str = "src/behaviors_conceiver";

/// Files that must exist in both conceiver modules. Add to this list
/// only when both conceivers genuinely need the new file.
const REQUIRED_FILES: &[&str] = &[
    "mod.rs",
    "vector.rs",
    "generator.rs",
    "commands.rs",
];

#[test]
fn both_conceivers_have_required_files() {
    for file in REQUIRED_FILES {
        let bb = format!("{}/{}", BLUEBOOK_DIR, file);
        let bh = format!("{}/{}", BEHAVIORS_DIR, file);
        assert!(Path::new(&bb).exists(), "missing {} in bluebook conceiver", bb);
        assert!(Path::new(&bh).exists(), "missing {} in behaviors conceiver", bh);
    }
}

#[test]
fn no_extra_files_without_a_twin() {
    // Every Rust source file in either conceiver dir must have a
    // namesake in the other — or be added to the allow list below.
    let allow: BTreeSet<&str> = ["develop.rs"].into_iter().collect();

    let bb_files = list_rs_files(BLUEBOOK_DIR);
    let bh_files = list_rs_files(BEHAVIORS_DIR);

    for f in bb_files.difference(&bh_files) {
        assert!(
            allow.contains(f.as_str()),
            "{} exists only in bluebook conceiver — add it to behaviors_conceiver/ \
             or to the allow list in conceiver_parity_test.rs",
            f,
        );
    }
    for f in bh_files.difference(&bb_files) {
        assert!(
            allow.contains(f.as_str()),
            "{} exists only in behaviors conceiver — add it to conceiver/ \
             or to the allow list in conceiver_parity_test.rs",
            f,
        );
    }
}

/// Both conceivers implement the same trait. This compiles, therefore
/// it passes. Kept as a runtime assertion so the test name documents
/// the contract — if either conceiver stops implementing Conceiver,
/// this file no longer compiles and the failure is loud.
#[test]
fn both_conceivers_implement_conceiver_trait() {
    fn assert_conceiver<C: Conceiver>() {}
    assert_conceiver::<BluebookConceiver>();
    assert_conceiver::<BehaviorsConceiver>();
}

/// Vector outputs are non-empty and have a stable dimensionality.
/// Drifts where one conceiver adds a dim and the other doesn't are
/// fine — but the dimensionality must be intentional, not zero.
#[test]
fn vector_extractors_produce_non_empty_vectors() {
    let domain = small_domain();
    let bb_vec = hecks_life::conceiver::vector::extract_vector(&domain);
    assert!(!bb_vec.is_empty(), "bluebook vector is empty");
    assert_eq!(bb_vec.len(), 9, "bluebook vector length should be 9 (drift if changed)");

    let suite = small_suite();
    let bh_vec = hecks_life::behaviors_conceiver::vector::extract_vector(&suite);
    assert!(!bh_vec.is_empty(), "behaviors vector is empty");
    assert_eq!(bh_vec.len(), 7, "behaviors vector length should be 7 (drift if changed)");
}

/// Both conceivers must be runnable end-to-end against a minimal
/// in-memory input. Catches "implements the trait but its generator
/// panics on small inputs" kinds of drift.
#[test]
fn both_conceivers_generate_without_panicking() {
    let domain = small_domain();
    let suite = small_suite();
    let _bb = BluebookConceiver::generate(&"a simple domain".to_string(), &domain);
    let _bh = BehaviorsConceiver::generate(&domain, &suite);
}

// ─── fixtures ────────────────────────────────────────────────────────

fn list_rs_files(dir: &str) -> BTreeSet<String> {
    fs::read_dir(dir).expect(dir).flatten()
        .filter_map(|e| {
            let p = e.path();
            if p.extension().map(|e| e == "rs").unwrap_or(false) {
                p.file_name().and_then(|n| n.to_str()).map(String::from)
            } else { None }
        })
        .collect()
}

fn small_domain() -> Domain {
    let source = r#"Hecks.bluebook "Mini" do
  vision "tiny domain"
  aggregate "Widget" do
    attribute :name, String
    command "Create" do
      attribute :name, String
    end
  end
end
"#;
    hecks_life::parser::parse(source)
}

fn small_suite() -> TestSuite {
    let source = r#"Hecks.behaviors "Mini" do
  vision "tiny suite"
  test "Create sets name" do
    tests "Create", on: "Widget"
    input  name: "x"
    expect name: "x"
  end
end
"#;
    hecks_life::behaviors_parser::parse(source)
}
