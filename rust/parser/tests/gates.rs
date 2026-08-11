//! Integration tests — drives the actual `hecks-parse` binary as a
//! subprocess against `tests/fixtures/*`, the same "shell out and check
//! the real exit code/stderr" discipline `spec/parser_parity_spec.rb`
//! (Ruby side) uses. Confirms the plan's own core Stage-1 claim: every
//! fixture fails CLOSED with a real, named diagnostic — never silently
//! succeeds, never panics, never claims coverage it doesn't have.

use std::path::PathBuf;
use std::process::{Command, Output};

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)
}

fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_hecks-parse")).args(args).output().expect("failed to run hecks-parse")
}

#[test]
fn every_bluebook_fixture_fails_closed_naming_its_own_construct() {
    let cases: &[(&str, &str, &str)] = &[
        ("aggregate.bluebook", "FixtureAggregate", "Aggregate"),
        ("entity.bluebook", "FixtureEntity", "Entity"),
        ("command.bluebook", "FixtureCommand", "Command"),
        ("query.bluebook", "FixtureQuery", "Query"),
        ("value_object.bluebook", "FixtureValueObject", "ValueObject"),
        ("read_model.bluebook", "FixtureReadModel", "ReadModel"),
        ("policy.bluebook", "FixturePolicy", "Policy"),
        ("process_manager.bluebook", "FixtureProcessManager", "ProcessManager"),
        ("lifecycle.bluebook", "FixtureLifecycle", "Lifecycle"),
    ];

    for (file, chapter, expected_construct) in cases {
        let path = fixture(file);
        let output = run(&["chapter", "--chapter", chapter, path.to_str().unwrap()]);
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);

        assert_eq!(output.status.code(), Some(1), "{file}: expected exit 1 (parse error). stdout={stdout} stderr={stderr}");
        assert!(stdout.is_empty(), "{file}: stdout must stay empty on a Stage 1 failure — never a partial/fabricated ir.json, got {stdout}");
        assert!(stderr.contains("not yet implemented"), "{file}: expected a not-yet-implemented diagnostic, got: {stderr}");
        assert!(
            stderr.contains(expected_construct),
            "{file}: expected the diagnostic to name {expected_construct}, got: {stderr}"
        );
    }
}

#[test]
fn hecksagon_fixtures_also_fail_closed() {
    let cases: &[(&str, &str)] = &[("hecksagon.hecksagon", "Hecksagon"), ("domain_port.hecksagon", "DomainPort")];

    for (file, expected_construct) in cases {
        let path = fixture(file);
        let output = run(&["resolve", path.to_str().unwrap()]);
        let stderr = String::from_utf8_lossy(&output.stderr);

        assert_eq!(output.status.code(), Some(1), "{file}: expected exit 1. stderr={stderr}");
        assert!(stderr.contains("not yet implemented"), "{file}: expected a not-yet-implemented diagnostic, got: {stderr}");
        assert!(stderr.contains(expected_construct), "{file}: expected the diagnostic to name {expected_construct}, got: {stderr}");
    }
}

#[test]
fn a_real_grammar_violation_is_a_hard_error_not_a_stub() {
    // A deliberately malformed file — `aggregate` is not a word `File`
    // context admits (it's `bluebook`'s own inner Aggregate context) —
    // must be refused by the WORD gate itself, distinctly worded from
    // "not yet implemented".
    let dir = std::env::temp_dir().join(format!("hecks_parse_gate_test_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("malformed.bluebook");
    std::fs::write(&path, "aggregate \"Widget\" do\nend\n").unwrap();

    let output = run(&["chapter", "--chapter", "Whatever", path.to_str().unwrap()]);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert_eq!(output.status.code(), Some(1));
    assert!(!stderr.contains("not yet implemented"), "a genuine grammar violation must not read as a stub: {stderr}");
    assert!(stderr.contains("is not a word"), "expected a word-gate diagnostic, got: {stderr}");

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn a_bare_if_is_refused_by_the_shape_gate() {
    let dir = std::env::temp_dir().join(format!("hecks_parse_shape_test_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("bare_if.bluebook");
    std::fs::write(&path, "bluebook \"X\" do\n  if true\n  end\nend\n").unwrap();

    let output = run(&["chapter", "--chapter", "X", path.to_str().unwrap()]);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert_eq!(output.status.code(), Some(1));
    assert!(stderr.contains("if"), "expected the shape gate to name the bare 'if', got: {stderr}");

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn coverage_prints_a_real_honest_empty_list_at_stage_1() {
    let output = run(&["coverage"]);
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert_eq!(stdout.trim(), "[]", "Stage 1 has no fully-built construct yet — coverage must not overclaim");
}

#[test]
fn usage_errors_exit_2() {
    let output = run(&[]);
    assert_eq!(output.status.code(), Some(2));

    let output = run(&["bogus-subcommand"]);
    assert_eq!(output.status.code(), Some(2));
}
