//! Cold-CLI `query` READ-ONLY guard.
//!
//! `storehouse query <root> <Domain::Aggregate.verb>` is the read-only door. A
//! query verb is snake_case ; a PascalCase tail is a COMMAND. Before the guard,
//! the `query` arm handed the verb straight to dispatch_hecksagon, which matches
//! the tail against query names by snake_case — a command tail matched none and
//! fell through to the MUTATING command path. So `storehouse query <root>
//! Gadget.Rename sku=a name=hacked` actually renamed the gadget : a read that
//! writes. The MCP shim guarded this in JS ; the bare CLI did not.
//!
//! Assertions are isolation-independent : the guard exits BEFORE any dispatch,
//! so the command's result JSON (which would echo the mutated `name`) never
//! prints. That absence — not a store read-back — is the proof the write was
//! stopped, and it does not depend on where the runtime persists. A unique
//! bluebook name avoids colliding with any real app-support store.

use std::process::Command;

const DEMO: &str = r#"Hecks.bluebook "QueryGuardDemo" do
  aggregate "Gadget" do
    identified_by :sku
    attribute :sku, Sku
    attribute :name, GadgetName
    value_object "Sku" do
      attribute :value, String
    end
    value_object "GadgetName" do
      attribute :value, String
    end
    command "Rename" do
      role "Clerk"
      attribute :sku, Sku
      attribute :name, GadgetName
      then_set :name, to: :name
    end
    query "by_sku" do
      where(sku: :sku)
    end
  end
end
"#;

fn temp_root(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("hecks_query_readonly_{}_{}", tag, std::process::id()));
    std::fs::create_dir_all(&dir).expect("mkdir temp root");
    std::fs::write(dir.join("query_guard_demo.bluebook"), DEMO).expect("write fixture");
    dir
}

// Invoke the binary with an explicit, full argv (the caller positions the root,
// since positional dispatch takes it first but `query` takes it second).
fn run(args: &[&str]) -> std::process::Output {
    let bin = env!("CARGO_BIN_EXE_storehouse");
    let mut cmd = Command::new(bin);
    for a in args {
        cmd.arg(a);
    }
    cmd.env_remove("HECKS_GOVERNANCE_OFF");
    cmd.output().expect("invoke storehouse")
}

#[test]
fn query_refuses_a_pascalcase_command_tail() {
    let root = temp_root("refuse");
    let r = root.to_str().unwrap();

    // Attempt to MUTATE through the read-only query door.
    let out = run(&["query", r, "QueryGuardDemo::Gadget.Rename", "sku=a", "name=hacked"]);

    assert_eq!(out.status.code(), Some(2),
        "query with a PascalCase (command) tail must be REFUSED (exit 2); stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    assert!(String::from_utf8_lossy(&out.stderr).contains("read-only"),
        "stderr should explain the read-only refusal: {}", String::from_utf8_lossy(&out.stderr));
    // Load-bearing : the command NEVER ran, so its result (which would echo the
    // new name) never printed. Isolation-independent proof the write was stopped.
    assert!(!String::from_utf8_lossy(&out.stdout).contains("hacked"),
        "the refused query must not have dispatched the command; stdout: {}",
        String::from_utf8_lossy(&out.stdout));
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn query_allows_a_snake_case_query() {
    let root = temp_root("allow");
    let r = root.to_str().unwrap();

    // A legitimate snake_case query is admitted and runs (the guard does not
    // over-reach). We assert it RAN, not its rows — rows depend on persistence.
    let out = run(&["query", r, "QueryGuardDemo::Gadget.by_sku", "sku=a"]);

    assert!(out.status.success(),
        "a snake_case query must be admitted (not refused); stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    assert!(String::from_utf8_lossy(&out.stdout).contains("\"query\":\"by_sku\""),
        "the snake_case query should run and report itself: {}",
        String::from_utf8_lossy(&out.stdout));
    let _ = std::fs::remove_dir_all(&root);
}
