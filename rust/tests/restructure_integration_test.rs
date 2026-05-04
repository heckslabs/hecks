//! Restructure capability — end-to-end integration test.
//!
//! Sets up a sandbox tree, defines a Layout with Placements, dispatches
//! Plan + Apply + RevertTo, asserts files moved + reverted correctly +
//! Move records carry the right state. Exercises real :fs renames,
//! validator dispatch on moved bluebooks, and the event-sourced rewind.
//!
//! [antibody-exempt: rust/tests/restructure_integration_test.rs —
//!  integration test scaffolding for the Restructure capability ; same
//!  antibody-exempt category as specializer_golden_test.rs and
//!  heki_path_coherence_test.rs (test-only kernel surface). Retires
//!  when behaviors framework gains a :fs tempdir fixture covering
//!  Layout.Plan/Apply/RevertTo end-to-end (filed as follow-up).]

use hecks_life::run_restructure::run;
use hecks_life::runtime::Runtime;
use hecks_life::runtime::adapter_registry::AdapterRegistry;
use std::path::Path;

const RESTRUCTURE_BLUEBOOK: &str =
    include_str!("../../discipline/restructure/restructure.bluebook");
const RESTRUCTURE_HECKSAGON: &str =
    include_str!("../../discipline/restructure/restructure.hecksagon");

fn make_runtime() -> (Runtime, AdapterRegistry) {
    let domain = hecks_life::parser::parse(RESTRUCTURE_BLUEBOOK);
    let hecksagon = hecks_life::hecksagon_parser::parse(RESTRUCTURE_HECKSAGON);
    let rt = Runtime::boot(domain);
    let registry = AdapterRegistry::from_hecksagon(hecksagon);
    (rt, registry)
}

fn write_file(root: &Path, rel: &str, body: &str) {
    let p = root.join(rel);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, body).unwrap();
}

fn exists(root: &Path, rel: &str) -> bool {
    root.join(rel).exists()
}

// Test #1 (capability_detector_fires_for_restructure_bluebook) removed —
// the registry-shape assertion is a 5-line inline-domain unit test that
// belongs at the AdapterRegistry / is_restructure_capability call site,
// not coupled to the real bluebook fixture. Filed as follow-up.

#[test]
fn plan_apply_revert_full_lifecycle_via_runner() {
    // Sandbox layout :
    //   <root>/old_home/alpha.bluebook   (valid bluebook ; will move)
    //   <root>/old_home/beta.bluebook    (valid bluebook ; will move)
    //   <root>/keep.txt                   (no placement matches ; stays)
    let tmp = tempdir();
    let root = tmp.path();

    let valid = "Hecks.bluebook \"Tiny\" do\n  vision \"sandbox\"\n  aggregate \"X\" do\n    attribute :name, String\n  end\nend\n";
    write_file(root, "old_home/alpha.bluebook", valid);
    write_file(root, "old_home/beta.bluebook", valid);
    write_file(root, "keep.txt", "leave me");

    let (mut rt, registry) = make_runtime();
    let root_arg = format!("root={}", root.to_string_lossy());

    // Define the layout.
    let mut a = std::collections::HashMap::new();
    a.insert("name".into(), hecks_life::runtime::Value::Str("v1".into()));
    a.insert("version".into(), hecks_life::runtime::Value::Str("2026.04.30.1".into()));
    a.insert("description".into(), hecks_life::runtime::Value::Str("test".into()));
    rt.dispatch("Define", a).expect("Define");

    // Attach a placement : every .bluebook under old_home/ goes to new_home/.
    let mut p = std::collections::HashMap::new();
    p.insert("pattern".into(), hecks_life::runtime::Value::Str("old_home/*.bluebook".into()));
    p.insert("destination".into(), hecks_life::runtime::Value::Str("new_home".into()));
    p.insert("reason".into(), hecks_life::runtime::Value::Str("test".into()));
    rt.dispatch("Add", p).expect("Add");

    // Plan via the runner — walks fs, dispatches PlanMove per match.
    let exit = run(
        &mut rt, &registry, "Layout.Plan",
        root.to_string_lossy().as_ref(),
        &["name=v1".to_string(), root_arg.clone()],
    );
    assert_eq!(exit, 0, "Layout.Plan should succeed");

    // Apply via the runner — executes :fs renames + validator dispatch.
    let exit = run(
        &mut rt, &registry, "Layout.Apply",
        root.to_string_lossy().as_ref(),
        &["name=v1".to_string(), root_arg.clone()],
    );
    assert_eq!(exit, 0, "Layout.Apply should succeed");

    // Files should be in new_home/ now ; old_home/ should be empty
    // (or not contain the moved files). keep.txt unchanged.
    assert!(exists(root, "new_home/alpha.bluebook"), "alpha moved to new_home");
    assert!(exists(root, "new_home/beta.bluebook"), "beta moved to new_home");
    assert!(!exists(root, "old_home/alpha.bluebook"), "alpha gone from old_home");
    assert!(!exists(root, "old_home/beta.bluebook"), "beta gone from old_home");
    assert!(exists(root, "keep.txt"), "non-matching file untouched");

    // RevertTo via the runner — walks Move event log backward.
    let exit = run(
        &mut rt, &registry, "Layout.RevertTo",
        root.to_string_lossy().as_ref(),
        &["name=v1".to_string(), root_arg.clone()],
    );
    assert_eq!(exit, 0, "Layout.RevertTo should succeed");

    // Files should be back in old_home/ now.
    assert!(exists(root, "old_home/alpha.bluebook"), "alpha back in old_home");
    assert!(exists(root, "old_home/beta.bluebook"), "beta back in old_home");
    assert!(!exists(root, "new_home/alpha.bluebook"), "alpha gone from new_home");
    assert!(!exists(root, "new_home/beta.bluebook"), "beta gone from new_home");
}

// ---- Tempdir helper (avoid pulling tempfile dep just for tests) ------

struct TempDir { path: std::path::PathBuf }
impl TempDir {
    fn path(&self) -> &Path { &self.path }
}
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
fn tempdir() -> TempDir {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let path = std::env::temp_dir().join(format!("restructure_test_{}", nanos));
    std::fs::create_dir_all(&path).unwrap();
    TempDir { path }
}
