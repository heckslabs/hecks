//! establish_keystone_test.rs — path-level proof for FINDING-keystone-dead-path.
//!
//! `authz_roster_test` proves the ENGINE : `complete_over` with inline domains
//! and `data_dir = None`. It could stay green forever while the DEPLOYED path
//! stayed dead — which is exactly what happened : the real boot.bluebook gates
//! `CompleteBoot` behind `from: "completing"`, the completion runtime's fresh
//! BootRun sat at "pending", and the dispatch died as a swallowed
//! LifecycleViolation, so no establishment write ever reached a real store.
//!
//! THIS test proves the PATH : it drives the `storehouse establish <root>`
//! CLI verb (the same invocation the deployed mindstream member runs), with
//! the REAL boot bluebook + hecksagon and the REAL authorization corpus
//! (include_str! — the shipped roster, not a replica), against a real
//! on-disk store — then asserts the RoleAssignment / Policy records EXIST ON
//! DISK afterwards by reading them back through a SECOND runtime (the CLI
//! query path, `storehouse <root> Authorization::RoleAssignment.active`).
//! Idempotence : a second establish still yields 3 assignments / 6 grants.
//!
//! [antibody-exempt: rust/cli/tests/establish_keystone_test.rs — kernel-floor
//!  path-level integration test ; asserts on CLI exit codes + persisted store
//!  state, so it is necessarily Rust. Same category as authz_roster_test.rs.]

use std::process::Command;

const BOOT_BLUEBOOK: &str = include_str!("../../../runtime/boot/bluebook/boot.bluebook");
const BOOT_HECKSAGON: &str = include_str!("../../../runtime/boot/bluebook/boot.hecksagon");
const AUTHZ: &str = include_str!(
    "../../../hecks_conception/aggregates/framework/authorization/authorization.bluebook"
);
/// The REAL CascadeRun chapter — its presence flips the runtime onto the
/// persistent transactional-outbox path (record_cascade_run + pump_outbox),
/// the path the deployed corpus takes. Without it the in-memory pump runs
/// instead and this test would miss the outbox-payload identity-stripping
/// regression (inject_refs' i151 heuristic vs the roster's `with` keys).
const CASCADE_RUN: &str = include_str!(
    "../../../hecks_conception/aggregates/framework/cascade/bluebook/cascade_run.bluebook"
);

/// A `.world` opting into `dir :default` — outside ~/Projects that resolves
/// to a co-located `<root>/.heki`, so the store lives (and dies) with the
/// tempdir and never touches the live OS data root.
const WORLD: &str = "Hecks.world \"EstablishTest\" do\n  heki do\n    dir :default\n  end\nend\n";

fn storehouse(args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_storehouse"))
        .args(args)
        // A stray principal stamp or conception override in the invoking
        // environment must not leak into the gate / root resolution.
        .env_remove("HECKS_SESSION_AUTH_ID")
        .env_remove("HECKS_PRINCIPAL_KIND")
        .env_remove("HECKS_CONCEPTION_DIR")
        .output()
        .expect("spawn storehouse")
}

/// Build `<tmp>/repo` with the real boot pipeline at its repo-anchored home
/// and a minimal conception (the real authorization corpus) under it.
/// Returns the conception root the verb takes.
fn setup(name: &str) -> std::path::PathBuf {
    let repo = std::env::temp_dir().join(name).join("repo");
    let _ = std::fs::remove_dir_all(repo.parent().unwrap());
    let boot_dir = repo.join("runtime/boot/bluebook");
    std::fs::create_dir_all(&boot_dir).unwrap();
    std::fs::write(boot_dir.join("boot.bluebook"), BOOT_BLUEBOOK).unwrap();
    std::fs::write(boot_dir.join("boot.hecksagon"), BOOT_HECKSAGON).unwrap();
    let root = repo.join("hecks_conception");
    let authz_dir = root.join("aggregates/framework/authorization");
    std::fs::create_dir_all(&authz_dir).unwrap();
    std::fs::write(authz_dir.join("authorization.bluebook"), AUTHZ).unwrap();
    let cascade_dir = root.join("aggregates/framework/cascade");
    std::fs::create_dir_all(&cascade_dir).unwrap();
    std::fs::write(cascade_dir.join("cascade_run.bluebook"), CASCADE_RUN).unwrap();
    std::fs::write(root.join("test.world"), WORLD).unwrap();
    root
}

/// Run a CLI query against the root and parse its JSON payload.
fn query(root: &str, verb: &str) -> serde_json::Value {
    let out = storehouse(&[root, verb]);
    assert!(out.status.success(), "query {} failed: {}", verb, String::from_utf8_lossy(&out.stderr));
    let stdout = String::from_utf8_lossy(&out.stdout);
    // The query result is the line(s) of JSON on stdout — grab the first
    // line that parses (dispatch logging goes to stderr).
    stdout.lines()
        .find_map(|l| serde_json::from_str(l.trim()).ok())
        .unwrap_or_else(|| panic!("no JSON in query output: {stdout}"))
}

/// The query payload is `{"aggregate": …, "query": …, "state": […records…]}` —
/// the records live under "state".
fn records(payload: &serde_json::Value) -> Vec<serde_json::Value> {
    payload.get("state").and_then(|s| s.as_array()).cloned().unwrap_or_default()
}

fn roster_counts(root: &str) -> (usize, usize) {
    let assignments = records(&query(root, "Authorization::RoleAssignment.active"));
    let policies = records(&query(root, "Authorization::Policy.active"));
    // The Active projection carries the rule fields, not the record id —
    // count the roster grants by their principals (the two roster roles).
    let n_roster = policies.iter()
        .filter(|p| {
            p.get("principal").and_then(|v| v.as_str())
                .map_or(false, |s| s == "pr-agent" || s == "workflow-subagent")
        })
        .count();
    (assignments.len(), n_roster)
}

/// The keystone, end to end on the deployed path : `establish` exits 0, the
/// roster lands ON DISK (a second runtime reads it back), and a second
/// establish is idempotent — still 3 assignments, still 6 roster grants.
#[test]
fn establish_persists_the_roster_and_is_idempotent() {
    let root = setup("hecks_establish_keystone");
    let root_s = root.to_str().unwrap();

    let out = storehouse(&["establish", root_s]);
    assert!(
        out.status.success(),
        "establish failed — stdout: {} stderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("established:"),
        "establish must report what it did"
    );

    // Persistence proof the engine test lacks : the records exist ON DISK —
    // the co-located world store holds the roster, and a SECOND runtime
    // (the CLI query path) reads it back.
    let store = root.join(".heki");
    assert!(store.is_dir(), "establish must persist to the root's world store (.heki)");
    assert!(
        store.join("authorization/role_assignment.heki").is_file(),
        "RoleAssignment records must exist on disk after establish"
    );

    let (assignments, roster_grants) = roster_counts(root_s);
    assert_eq!(assignments, 3, "roster must assign pr-agent, workflow-subagent, sidequest");
    assert_eq!(roster_grants, 6, "the six roster grants must be active");

    // Idempotence : re-establish upserts on natural keys, never duplicates.
    let again = storehouse(&["establish", root_s]);
    assert!(again.status.success(), "second establish must succeed");
    let (assignments, roster_grants) = roster_counts(root_s);
    assert_eq!(assignments, 3, "re-establish must not duplicate assignments");
    assert_eq!(roster_grants, 6, "re-establish must not duplicate grants");
}

/// A root with no repo-anchored boot bluebook is a clear, loud error — not a
/// silent in-memory "success".
#[test]
fn establish_without_boot_bluebook_fails_loudly() {
    let dir = std::env::temp_dir().join("hecks_establish_no_boot");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let out = storehouse(&["establish", dir.to_str().unwrap()]);
    assert!(!out.status.success(), "establish without a boot bluebook must fail");
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("boot.bluebook"),
        "the error must name the missing boot bluebook"
    );
}
