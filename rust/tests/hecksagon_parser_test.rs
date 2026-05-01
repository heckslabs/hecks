//! Hecksagon parser tests — pin the shapes the runtime depends on.
//!
//! The antibody.hecksagon test is the acceptance target: prior to this
//! PR the Rust parser produced an empty domain; after, it returns seven
//! shell adapters + three gates + memory persistence.

use hecks_life::hecksagon_parser;

const ANTIBODY: &str = r#"Hecks.hecksagon "Antibody" do
  adapter :memory

  adapter :shell,
          name:    :git_resolve_ref,
          command: "git rev-parse --verify {{ref}}",
          ok_exit: 0

  adapter :shell,
          name:    :git_list_commits,
          command: "git log --format=%H --reverse {{base_ref}}..HEAD",
          ok_exit: 0

  adapter :shell,
          name:    :git_show_touched,
          command: "git show --name-only --diff-filter=AM --format= {{sha}}",
          ok_exit: 0

  adapter :shell,
          name:    :git_commit_message,
          command: "git log -1 --format=%B {{sha}}",
          ok_exit: 0

  adapter :shell,
          name:    :git_commit_subject,
          command: "git log -1 --format=%s {{sha}}",
          ok_exit: 0

  adapter :shell,
          name:    :git_branch_diff,
          command: "git diff --name-only --diff-filter=AM {{base_ref}}...HEAD",
          ok_exit: 0

  adapter :shell,
          name:    :git_staged_files,
          command: "git diff --cached --name-only --diff-filter=AM",
          ok_exit: 0

  gate "CommitCheck", :ci do
    allow :ValidateCommit, :ExemptCommit, :RejectCommit
  end

  gate "BranchScan", :ci do
    allow :ScanBranch, :ScanEachCommit, :ScanUnresolvable
  end

  gate "StagedCheck", :hook do
    allow :CheckStaged, :EnforceStaged, :ExemptStaged, :RejectStaged
  end
end
"#;

#[test]
fn detects_hecksagon_source() {
    assert!(hecksagon_parser::is_hecksagon_source(ANTIBODY));
    assert!(!hecksagon_parser::is_hecksagon_source("Hecks.bluebook \"X\" do\nend"));
}

#[test]
fn parses_antibody_to_seven_shell_adapters() {
    let hex = hecksagon_parser::parse(ANTIBODY);
    assert_eq!(hex.name, "Antibody");
    assert_eq!(hex.persistence.as_deref(), Some("memory"));
    assert_eq!(hex.shell_adapters.len(), 7, "expected 7 shell adapters");
    let names: Vec<&str> = hex.shell_adapters.iter().map(|a| a.name.as_str()).collect();
    assert!(names.contains(&"git_resolve_ref"));
    assert!(names.contains(&"git_staged_files"));
}

#[test]
fn shell_adapter_splits_command_and_args() {
    let hex = hecksagon_parser::parse(ANTIBODY);
    let sa = hex.shell_adapter("git_resolve_ref").expect("missing adapter");
    assert_eq!(sa.command, "git");
    assert_eq!(sa.args, vec!["rev-parse", "--verify", "{{ref}}"]);
    assert_eq!(sa.placeholders(), vec!["ref"]);
    assert_eq!(sa.ok_exit, 0);
}

#[test]
fn parses_three_gates_with_allowed_commands() {
    let hex = hecksagon_parser::parse(ANTIBODY);
    assert_eq!(hex.gates.len(), 3);
    let staged = hex.gate_for("StagedCheck", "hook").expect("missing gate");
    assert!(staged.allowed_commands.contains(&"CheckStaged".to_string()));
    assert!(staged.allowed_commands.contains(&"RejectStaged".to_string()));
}

#[test]
fn parses_explicit_args_vector_and_options() {
    let src = r#"Hecks.hecksagon "X" do
  adapter :shell,
          name: :git_log,
          command: "git",
          args: ["log", "--format=%H", "{{range}}"],
          output_format: :lines,
          timeout: 10,
          working_dir: ".",
          env: { "GIT_PAGER" => "" }
end
"#;
    let hex = hecksagon_parser::parse(src);
    let sa = hex.shell_adapter("git_log").unwrap();
    assert_eq!(sa.command, "git");
    assert_eq!(sa.args, vec!["log", "--format=%H", "{{range}}"]);
    assert_eq!(sa.output_format, "lines");
    assert_eq!(sa.timeout, Some(10));
    assert_eq!(sa.working_dir.as_deref(), Some("."));
    assert_eq!(sa.env, vec![("GIT_PAGER".to_string(), "".to_string())]);
}

#[test]
fn parses_io_adapters_and_subscriptions() {
    let src = r#"Hecks.hecksagon "Cap" do
  adapter :stdout
  adapter :stdin
  adapter :env, keys: ["PATH"]
  subscribe "Heartbeat"
end
"#;
    let hex = hecksagon_parser::parse(src);
    assert!(hex.io_adapter("stdout").is_some());
    assert!(hex.io_adapter("stdin").is_some());
    let env = hex.io_adapter("env").unwrap();
    assert!(env.options.iter().any(|(k, _)| k == "keys"));
    assert_eq!(hex.subscriptions, vec!["Heartbeat".to_string()]);
}
