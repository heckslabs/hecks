//! Integration tests for the `storehouse run` script-mode subcommand.
//!
//! Builds a tempdir with a bluebook + companion hecksagon, invokes
//! storehouse::run::run_script, and asserts the right exit code.

use storehouse::run::{self, ExitKind};

fn tempdir_with(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("hecks-run-test-{}-{}", name, std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn missing_path_is_parse_failure() {
    let args = vec!["storehouse".into(), "run".into()];
    assert_eq!(run::run_script(&args), ExitKind::ParseFailure.code());
}

#[test]
fn unreadable_path_is_parse_failure() {
    let args = vec!["storehouse".into(), "run".into(), "/does/not/exist.bluebook".into()];
    assert_eq!(run::run_script(&args), ExitKind::ParseFailure.code());
}

#[test]
fn bluebook_without_entrypoint_is_guard_failure() {
    let dir = tempdir_with("noentry");
    let bb = dir.join("x.bluebook");
    std::fs::write(&bb, "Hecks.bluebook \"Silent\" do\n  aggregate \"Thing\" do\n    command \"DoIt\"\n  end\nend\n").unwrap();
    let args = vec!["storehouse".into(), "run".into(), bb.to_string_lossy().into()];
    assert_eq!(run::run_script(&args), ExitKind::GuardFailure.code());
}

#[test]
fn unknown_entrypoint_is_command_not_found() {
    let dir = tempdir_with("badentry");
    let bb = dir.join("x.bluebook");
    std::fs::write(&bb, "Hecks.bluebook \"BadEntry\" do\n  entrypoint \"NoSuchCommand\"\n  aggregate \"Thing\" do\n    command \"DoIt\"\n  end\nend\n").unwrap();
    let args = vec!["storehouse".into(), "run".into(), bb.to_string_lossy().into()];
    assert_eq!(run::run_script(&args), ExitKind::CommandNotFound.code());
}

#[test]
fn valid_script_exits_zero() {
    let dir = tempdir_with("happy");
    let bb = dir.join("x.bluebook");
    std::fs::write(&bb, "#!/usr/bin/env storehouse run\nHecks.bluebook \"Happy\" do\n  entrypoint \"DoIt\"\n  aggregate \"Thing\" do\n    command \"DoIt\"\n  end\nend\n").unwrap();
    let args = vec!["storehouse".into(), "run".into(), bb.to_string_lossy().into()];
    assert_eq!(run::run_script(&args), ExitKind::Ok.code());
}

#[test]
fn spaced_arg_value_survives_dispatch_end_to_end() {
    // GAP 2 (usecase-step-arg-spaces). A use-case step arg whose value
    // contains spaces (e.g. title="serve-hook probe") is built by
    // story_args_to_tokens as ONE token "title=serve-hook probe". It must
    // survive route -> run_script -> dispatch -> heki with spaces intact.
    // run_script parses each argv element with splitn(2,'='), which keeps
    // spaces WITHIN the value, so the full phrase must land on the record.
    let dir = tempdir_with("spaced");
    let bb = dir.join("note.bluebook");
    std::fs::write(&bb,
        "Hecks.bluebook \"Note\" do\n  entrypoint \"Write\"\n  aggregate \"Note\" do\n    identified_by :id\n    attribute :id, String\n    attribute :title, String\n    command \"Write\" do\n      attribute :id, String\n      attribute :title, String\n      then_set :title, to: :title\n      emits \"NoteWritten\"\n    end\n  end\nend\n").unwrap();
    let hex = dir.join("note.hecksagon");
    std::fs::write(&hex,
        "Hecks.hecksagon \"Note\" do\n  adapter :fs\nend\n").unwrap();

    // First reproduce the token-building step the runner performs.
    let tokens = storehouse::story_runtime::story_args_to_tokens(
        "{\"id\":\"n1\",\"title\":\"serve-hook probe\"}");
    assert!(tokens.iter().any(|t| t == "title=serve-hook probe"),
        "story_args_to_tokens must keep the spaced value in one token: {:?}", tokens);

    // Pin HECKS_INFO to the tempdir so the fs adapter persists here.
    let prev = std::env::var("HECKS_INFO").ok();
    std::env::set_var("HECKS_INFO", dir.to_string_lossy().to_string());

    let mut args = vec!["storehouse".into(), "run".into(), bb.to_string_lossy().into()];
    args.extend(tokens);
    let code = run::run_script(&args);

    match &prev {
        Some(v) => std::env::set_var("HECKS_INFO", v),
        None => std::env::remove_var("HECKS_INFO"),
    }
    assert_eq!(code, ExitKind::Ok.code(), "dispatch with spaced arg should succeed");

    let heki_path = storehouse::heki::path_for_lookup(&dir.to_string_lossy(), "note");
    let store = storehouse::heki::read(&heki_path).expect("note heki readable");
    let rec = store.get("n1").expect("record n1 persisted");
    assert_eq!(rec.get("title").and_then(|v| v.as_str()), Some("serve-hook probe"),
        "spaced title value must land intact on the persisted record");
}

#[test]
fn run_script_fires_claude_tool_adapter_side_effect() {
    // Regression for the use-case step-runner adapter gap : a step whose
    // phrase is a `:claude_tool` command (e.g. ShellTool.Bash) recorded its
    // event but never fired the side-effect adapter, because run_script
    // booted with an EMPTY `rt.hecksagons` and the
    // `resolve_claude_tool_adapters` arm early-returns on empty hecksagons.
    // After the fix run_script attaches the companion hecksagon, so the
    // adapter fires and the shell command's side effect (a touched file)
    // becomes observable — mirroring the direct main.rs dispatch path.
    let dir = tempdir_with("claude-tool-fire");
    let probe = dir.join("adapter_fired.txt");
    let _ = std::fs::remove_file(&probe);

    let bb = dir.join("shell.bluebook");
    std::fs::write(&bb,
        "Hecks.bluebook \"Shell\" do\n  entrypoint \"Bash\"\n  aggregate \"ShellTool\" do\n    identified_by :id\n    attribute :id, String\n    attribute :shell_command, String\n    command \"Bash\" do\n      attribute :id, String\n      attribute :shell_command, String\n      then_set :shell_command, to: :shell_command\n      emits \"BashRan\"\n    end\n  end\nend\n").unwrap();
    // Companion hecksagon carries the :claude_tool adapter binding —
    // command "ShellTool.Bash" → tool :bash. The bash dispatcher reads the
    // `shell_command` attr and shells out, so the touch creates the probe.
    let hex = dir.join("shell.hecksagon");
    std::fs::write(&hex,
        "Hecks.hecksagon \"Shell\" do\n  adapter :memory\n  adapter :claude_tool, command: \"ShellTool.Bash\", tool: :bash\nend\n").unwrap();

    let args = vec![
        "storehouse".into(),
        "run".into(),
        bb.to_string_lossy().into(),
        "id=fire1".into(),
        format!("shell_command=touch {}", probe.to_string_lossy()),
    ];
    let code = run::run_script(&args);
    assert_eq!(code, ExitKind::Ok.code(), "dispatch should succeed");
    assert!(probe.exists(),
        "the :claude_tool adapter must fire on the run_script path and create {}",
        probe.display());
}

#[test]
fn companion_hecksagon_is_loaded_when_sibling_exists() {
    let dir = tempdir_with("sibling");
    let bb = dir.join("greet.bluebook");
    std::fs::write(&bb, "Hecks.bluebook \"Greet\" do\n  entrypoint \"DoIt\"\n  aggregate \"Thing\" do\n    command \"DoIt\"\n  end\nend\n").unwrap();
    let hex = dir.join("greet.hecksagon");
    std::fs::write(&hex, "Hecks.hecksagon \"Greet\" do\n  adapter :memory\n  adapter :stdout\nend\n").unwrap();
    let (_, parsed_hex) = run::load_script(bb.to_str().unwrap()).unwrap();
    assert_eq!(parsed_hex.name, "Greet");
    assert_eq!(parsed_hex.persistence.as_deref(), Some("memory"));
    assert!(parsed_hex.io_adapter("stdout").is_some());
}
