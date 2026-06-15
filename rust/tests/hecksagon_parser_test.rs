//! Hecksagon parser tests — pin the shapes the runtime depends on.
//!
//! The antibody.hecksagon test is the acceptance target: prior to this
//! PR the Rust parser produced an empty domain; after, it returns seven
//! shell adapters + three gates + memory persistence.

use storehouse::hecksagon_parser;

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
    // bucket-3 — the `*.family` / `*.adapter` top-level forms detect as
    // hecksagon source too (same parser, new detector keywords).
    assert!(hecksagon_parser::is_hecksagon_source("Hecks.family \"persistence\" do\nend"));
    assert!(hecksagon_parser::is_hecksagon_source("Hecks.adapter \"Heki\" do\nend"));
}

// bucket-3 step 1 — a `.family` declaration parses into a single Family
// carrying verb / signal / fields. Trailing `#` comments and irregular
// spacing on the inner lines must NOT ride into the IR.
const PERSISTENCE_FAMILY: &str = r#"# persistence — an impure-boundary PORT
Hecks.family "persistence" do
  verb   "persisted_by"   # the how-verb the bind hangs off the FQN
  signal :reply           # returns a value to the synchronous domain
  field  :dir             # WHERE the store writes ; value in .world
end
"#;

#[test]
fn parses_family_verb_signal_and_fields() {
    let hex = hecksagon_parser::parse(PERSISTENCE_FAMILY);
    assert_eq!(hex.families.len(), 1, "expected one family");
    let fam = &hex.families[0];
    assert_eq!(fam.name, "persistence");
    assert_eq!(fam.verb, "persisted_by");
    assert_eq!(fam.signal, "reply", "signal token must drop the colon AND the trailing comment");
    assert_eq!(fam.fields, vec!["dir".to_string()], "field token must drop the colon AND the trailing comment");
}

// bucket-3 step 1 — an `.adapter` declaration parses into a single Adapter
// naming the family it implements (the inverted arrow).
const HEKI_ADAPTER: &str = r#"# Heki — a concrete async PERSISTENCE adapter
Hecks.adapter "Heki" do
  family "persistence"
end
"#;

#[test]
fn parses_adapter_decl_with_family() {
    let hex = hecksagon_parser::parse(HEKI_ADAPTER);
    assert_eq!(hex.adapters.len(), 1, "expected one adapter");
    let ad = &hex.adapters[0];
    assert_eq!(ad.name, "Heki");
    assert_eq!(ad.family, "persistence");
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

#[test]
fn routes_sqlite_adapter_into_persistence_with_db_option() {
    // `adapter :sqlite, db: "..."` must land in persistence (kind +
    // options), NOT in io_adapters. Mirrors Ruby's HecksagonBuilder,
    // which folds :sqlite/:postgres/:mysql into @persistence.
    let src = r#"Hecks.hecksagon "DailyMusing" do
  adapter :sqlite, db: "/tmp/yc_demo/daily_musing.db"
end
"#;
    let hex = hecksagon_parser::parse(src);
    assert_eq!(hex.persistence.as_deref(), Some("sqlite"));
    assert!(hex.io_adapter("sqlite").is_none(), "sqlite must not be an io_adapter");
    assert_eq!(
        hex.persistence_option("db").map(|s| s.trim_matches('"')),
        Some("/tmp/yc_demo/daily_musing.db"),
    );
}

#[test]
fn parses_canned_block_inside_driven_handler() {
    // Sprint 14 memory-canned-defaults — `canned do ... end` declared
    // inside a `driven on` handler captures key/value pairs that stand
    // in for the wrapped call's return when no `.world` adapter entry
    // binds this adapter. The values keep their source-token form
    // (quoted strings retain their quotes, ints stay as digit strings)
    // so the resolver applies build_attr_map at fire time.
    let src = r#"Hecks.hecksagon "Tools" do
  adapter "Shell" do
    driven on "Tools::ShellTool.BashRan" do |e|
      canned do
        output "ack"
        exit_code 0
      end
      dispatch "Tools::TaskTool.Get", id: "shell-adapter-smoke"
    end
  end
end
"#;
    let hex = hecksagon_parser::parse(src);
    assert_eq!(hex.driven_adapters.len(), 1, "expected one DrivenAdapter");
    let adapter = &hex.driven_adapters[0];
    assert_eq!(adapter.name, "Shell");
    assert_eq!(adapter.handlers.len(), 1);
    let handler = &adapter.handlers[0];
    assert_eq!(handler.event_ref, "Tools::ShellTool.BashRan");
    let canned = handler.canned.as_ref().expect("canned block parsed");
    assert_eq!(canned.values.len(), 2);
    assert_eq!(canned.values[0], ("output".to_string(), "\"ack\"".to_string()));
    assert_eq!(canned.values[1], ("exit_code".to_string(), "0".to_string()));
    // The dispatch survives the canned block.
    assert_eq!(handler.dispatches.len(), 1);
    assert_eq!(handler.dispatches[0].command, "Tools::TaskTool.Get");
}

#[test]
fn handler_without_canned_block_leaves_canned_none() {
    // Sprint 14 — backwards-compat : a `driven on` handler without a
    // `canned do` block leaves DrivenHandler::canned as None, and the
    // existing dispatch parsing keeps working unchanged.
    let src = r#"Hecks.hecksagon "Tools" do
  adapter "Shell" do
    driven on "Tools::ShellTool.BashRan" do |e|
      dispatch "Tools::TaskTool.Get", id: "shell-adapter-smoke"
    end
  end
end
"#;
    let hex = hecksagon_parser::parse(src);
    let handler = &hex.driven_adapters[0].handlers[0];
    assert!(handler.canned.is_none());
    assert_eq!(handler.dispatches.len(), 1);
}

#[test]
fn parses_inline_canned_block() {
    // Sprint 14 — inline form `canned do; key value; key value end`
    // matches the same kv shape as the block form.
    let src = r#"Hecks.hecksagon "Tools" do
  adapter "Shell" do
    driven on "X.Y" do |e|
      canned do; output "ack"; exit_code 0 end
      dispatch "X.Z"
    end
  end
end
"#;
    let hex = hecksagon_parser::parse(src);
    let canned = hex.driven_adapters[0].handlers[0]
        .canned.as_ref().expect("inline canned");
    assert_eq!(canned.values.len(), 2);
    assert_eq!(canned.values[0].0, "output");
    assert_eq!(canned.values[1].0, "exit_code");
}
