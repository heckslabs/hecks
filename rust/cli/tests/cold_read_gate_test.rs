//! Cold-CLI read-gate regression test.
//!
//! Locks the contract: the one-shot CLI QUERY path is gated symmetrically with
//! the command path. Before 2026-06-29 the cold CLI called the UNGATED
//! `resolve_query*` core directly, so an unpermitted agent could READ any
//! aggregate while the command path correctly denied (authz read-bypass). The
//! runtime's `query()` entry was already gated (authorize_pdp_test's
//! query_deny_by_default) ; this proves the BINARY routes reads through the
//! gate. With deny-by-default and zero policies, an agent read is DENIED
//! (exit 2) and a System read is ADMITTED (exit 0) by origin.

use std::process::Command;

const VAULT: &str = r#"Hecks.bluebook "Vault" do
  aggregate "Box" do
    attribute :name, Name
    value_object "Name" do
      attribute :value, String
    end
    command "Open" do
      role "Keeper"
      attribute :name, Name
    end
    query "All" do
      where(name: "x")
    end
  end
end
"#;

fn temp_root(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("hecks_read_gate_{}_{}", tag, std::process::id()));
    std::fs::create_dir_all(&dir).expect("mkdir temp root");
    std::fs::write(dir.join("vault.bluebook"), VAULT).expect("write fixture");
    dir
}

fn run_read(root: &std::path::Path, agent: bool) -> std::process::Output {
    let bin = env!("CARGO_BIN_EXE_storehouse");
    let mut cmd = Command::new(bin);
    cmd.arg(root).arg("Vault::Box.all");
    // Never let an ambient deploy-floor escape mask the gate under test.
    cmd.env_remove("HECKS_GOVERNANCE_OFF");
    if agent {
        cmd.env("HECKS_PRINCIPAL_KIND", "agent")
           .env("HECKS_SESSION_AUTH_ID", "ghost");
    }
    cmd.output().expect("invoke storehouse")
}

#[test]
fn cold_read_denies_unpermitted_agent() {
    let root = temp_root("deny");
    let out = run_read(&root, true);
    assert_eq!(out.status.code(), Some(2),
        "agent read must be DENIED (exit 2); stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("denied"),
        "stderr should explain the denial: {}", stderr);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn cold_read_admits_system() {
    let root = temp_root("admit");
    let out = run_read(&root, false);
    assert!(out.status.success(),
        "System read must be admitted; stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("\"query\":\"All\""),
        "System read should return the query result: {}", stdout);
    let _ = std::fs::remove_dir_all(&root);
}
