//! Acceptance tests for the Rust ShellDispatcher.
//!
//! Exercises :text, :lines, :exit_code, timeout, and placeholder
//! substitution against real binaries available on macOS/Linux (echo,
//! printf, sh, sleep, false).

use hecks_life::hecksagon_ir::ShellAdapter;
use hecks_life::runtime::shell_dispatcher::{self, Output, DispatchError};
use std::collections::HashMap;

fn adapter(name: &str, command: &str, args: Vec<&str>) -> ShellAdapter {
    ShellAdapter {
        name: name.into(),
        command: command.into(),
        args: args.iter().map(|s| s.to_string()).collect(),
        output_format: "text".into(),
        timeout: None,
        working_dir: None,
        env: vec![],
        ok_exit: 0,
    }
}

#[test]
fn text_format_returns_raw_stdout() {
    let a = adapter("say", "echo", vec!["hello", "world"]);
    let r = shell_dispatcher::call(&a, &HashMap::new()).unwrap();
    match r.output {
        Output::Text(t) => assert!(t.contains("hello world")),
        other => panic!("expected Text, got {:?}", other),
    }
    assert_eq!(r.exit_status, 0);
}

#[test]
fn lines_format_splits_and_drops_empties() {
    let mut a = adapter("multi", "printf", vec!["line1\\nline2\\n\\nline3\\n"]);
    a.output_format = "lines".into();
    let r = shell_dispatcher::call(&a, &HashMap::new()).unwrap();
    match r.output {
        Output::Lines(lines) => assert_eq!(lines, vec!["line1", "line2", "line3"]),
        other => panic!("expected Lines, got {:?}", other),
    }
}

#[test]
fn placeholder_substitution_replaces_args() {
    let a = adapter("greet", "echo", vec!["hello", "{{name}}"]);
    let mut attrs = HashMap::new();
    attrs.insert("name".into(), "Miette".into());
    let r = shell_dispatcher::call(&a, &attrs).unwrap();
    match r.output {
        Output::Text(t) => assert!(t.contains("Miette")),
        _ => panic!("expected Text"),
    }
}

#[test]
fn non_zero_exit_raises_unless_format_is_exit_code() {
    let a = adapter("boom", "false", vec![]);
    match shell_dispatcher::call(&a, &HashMap::new()) {
        Err(DispatchError::NonZeroExit { exit_status, .. }) => assert_ne!(exit_status, 0),
        other => panic!("expected NonZeroExit, got {:?}", other),
    }
}

#[test]
fn exit_code_format_captures_status_and_never_raises() {
    let mut a = adapter("code", "false", vec![]);
    a.output_format = "exit_code".into();
    let r = shell_dispatcher::call(&a, &HashMap::new()).unwrap();
    match r.output {
        Output::ExitCode(code) => assert_ne!(code, 0),
        other => panic!("expected ExitCode, got {:?}", other),
    }
}

#[test]
fn timeout_kills_runaway_process() {
    let mut a = adapter("wait", "sleep", vec!["5"]);
    a.timeout = Some(1);
    match shell_dispatcher::call(&a, &HashMap::new()) {
        Err(DispatchError::Timeout { .. }) => {},
        other => panic!("expected Timeout, got {:?}", other),
    }
}

#[test]
fn env_entries_pass_through_baseline_is_cleared() {
    let mut a = adapter("show", "sh", vec!["-c", "echo $HECKS_TEST_VAR"]);
    a.env = vec![("HECKS_TEST_VAR".into(), "ok".into())];
    let r = shell_dispatcher::call(&a, &HashMap::new()).unwrap();
    match r.output {
        Output::Text(t) => assert_eq!(t.trim(), "ok"),
        other => panic!("expected Text, got {:?}", other),
    }
}
