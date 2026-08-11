//! Integration tests — drives the actual `hecks-parse` binary as a
//! subprocess against `tests/fixtures/*`, the same "shell out and check
//! the real exit code/stderr" discipline `spec/parser_parity_spec.rb`
//! (Ruby side) uses. Stage 1's core claim (every fixture fails CLOSED
//! with a real, named diagnostic — never silently succeeds, never
//! panics, never claims coverage it doesn't have) still holds for every
//! construct this crate has NOT built real IR for yet. STAGE 2 shrinks
//! `STILL_PENDING` below the same way `spec/parser_parity_spec.rb`'s own
//! `PENDING_MEMBERS`/`spec/parser_coverage_spec.rb`'s own
//! `STAGE_1_PENDING` shrink — `command.bluebook`/`query.bluebook`/
//! `value_object.bluebook`/`policy.bluebook`/`lifecycle.bluebook` now
//! parse for REAL (see `now_implemented_fixtures_parse_for_real` below),
//! since `parse::command`/`parse::query`/`parse::value_object`/
//! `parse::policy`/`parse::lifecycle` all stopped being stubs. STAGE 4
//! adds `process_manager.bluebook` to that same list (`parse::
//! process_manager`, previously fully stubbed).

use std::path::PathBuf;
use std::process::{Command, Output};

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)
}

fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_hecks-parse")).args(args).output().expect("failed to run hecks-parse")
}

#[test]
fn still_pending_bluebook_fixtures_fail_closed_naming_their_own_construct() {
    // STILL genuinely not built: `aggregate.bluebook`/`entity.bluebook`
    // both exercise `identified_by`'s bare-FIELD form specifically
    // (`identified_by :name`, not the bare-TYPE form pizzas.bluebook
    // uses, nor the SOURCE/block form governance.bluebook/
    // console_settings.bluebook use and `build/identity.rs` resolves) —
    // STAGE 4 shares this resolution between `parse::aggregate` and
    // `parse::entity` via `parse::mod::parse_identified_by` (`EntityBuilder
    // #identified_by` is, per its own comment, "the aggregate's method
    // line for line"), so BOTH now report the identical, construct-
    // agnostic diagnostic ("identified_by (bare-field form)") rather than
    // a per-construct-prefixed one — checked for that shared wording here
    // instead of a construct name. `process_manager.bluebook` moved to
    // `now_implemented_fixtures_parse_for_real` below — STAGE 4 taught
    // `parse::process_manager` to build real IR.
    let cases: &[(&str, &str)] = &[("aggregate.bluebook", "FixtureAggregate"), ("entity.bluebook", "FixtureEntity")];

    for (file, chapter) in cases {
        let path = fixture(file);
        let output = run(&["chapter", "--chapter", chapter, path.to_str().unwrap()]);
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);

        assert_eq!(output.status.code(), Some(1), "{file}: expected exit 1 (parse error). stdout={stdout} stderr={stderr}");
        assert!(stdout.is_empty(), "{file}: stdout must stay empty on a still-pending failure — never a partial/fabricated ir.json, got {stdout}");
        assert!(stderr.contains("not yet implemented"), "{file}: expected a not-yet-implemented diagnostic, got: {stderr}");
        assert!(
            stderr.contains("identified_by (bare-field form)"),
            "{file}: expected the shared bare-field-form diagnostic, got: {stderr}"
        );
    }
}

#[test]
fn now_implemented_fixtures_parse_for_real() {
    // Stage 2 taught `parse::command`/`parse::query`/`parse::value_object`/
    // `parse::policy`/`parse::lifecycle` to build real IR; STAGE 3 adds
    // `parse::read_model` (`report`'s own `description`/`include`/
    // `group_by`) — all six fixtures (unlike the ones above) now succeed
    // outright: exit 0, and stdout is real, non-empty `ir.json`, not a
    // diagnostic.
    let cases: &[(&str, &str)] = &[
        ("command.bluebook", "FixtureCommand"),
        ("query.bluebook", "FixtureQuery"),
        ("value_object.bluebook", "FixtureValueObject"),
        ("policy.bluebook", "FixturePolicy"),
        ("lifecycle.bluebook", "FixtureLifecycle"),
        ("read_model.bluebook", "FixtureReadModel"),
        ("process_manager.bluebook", "FixtureProcessManager"), // STAGE 4
    ];

    for (file, chapter) in cases {
        let path = fixture(file);
        let output = run(&["chapter", "--chapter", chapter, path.to_str().unwrap()]);
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);

        assert!(output.status.success(), "{file}: expected a clean parse now that its construct is built. stderr={stderr}");
        assert!(stdout.trim_start().starts_with('{'), "{file}: expected real ir.json on stdout, got: {stdout}");
        assert!(stdout.contains(&format!("\"name\": \"{chapter}\"")), "{file}: expected the chapter's own name in its ir.json, got: {stdout}");
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
fn coverage_now_reports_the_pairs_pizzas_bluebook_actually_exercises() {
    let output = run(&["coverage"]);
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("[\"aggregate\", \"Bluebook\"]"), "expected aggregate/Bluebook covered, got: {stdout}");
    assert!(stdout.contains("[\"sets\", \"Command\"]"), "expected sets/Command covered (the canonical spelling, not 'then_set'), got: {stdout}");
    assert!(stdout.contains("[\"where\", \"Query\"]"), "expected where/Query covered, got: {stdout}");
    assert!(stdout.contains("[\"port\", \"Hecksagon\"]"), "expected port/Hecksagon covered, got: {stdout}");
    // STAGE 3: `report`/ReadModel now has a real `parse::read_model` of
    // its own (console_settings.bluebook's own `Styles`/`Curated`).
    assert!(stdout.contains("[\"report\", \"Bluebook\"]"), "expected report/Bluebook covered, got: {stdout}");
    assert!(stdout.contains("[\"include\", \"ReadModel\"]"), "expected include/ReadModel covered, got: {stdout}");
    assert!(stdout.contains("[\"group_by\", \"ReadModel\"]"), "expected group_by/ReadModel covered, got: {stdout}");
    // STAGE 4: `entity`/`process_manager` now have real `parse_body`s of
    // their own (banking.bluebook's own `LedgerEntry`/`Settlement`, and
    // the concurrently-landed `compliance`/`interview` real corpus
    // members this stage's own work happened to fully cover too).
    assert!(stdout.contains("[\"identified_by\", \"Entity\"]"), "expected identified_by/Entity covered, got: {stdout}");
    assert!(stdout.contains("[\"correlates_by\", \"ProcessManager\"]"), "expected correlates_by/ProcessManager covered, got: {stdout}");
    assert!(stdout.contains("[\"dispatch\", \"Handler\"]"), "expected dispatch/Handler covered, got: {stdout}");
    // STILL not covered — the bare-FIELD `identified_by` form has no
    // real corpus member exercising it yet, so `Entity`'s OWN coverage
    // stays partial (real for the six words banking.bluebook's pieces
    // actually use, not a blanket claim).
    assert!(!stdout.contains("[\"has_many\", \"Aggregate\"]"), "has_many is still not built — coverage must not overclaim it: {stdout}");
}

#[test]
fn usage_errors_exit_2() {
    let output = run(&[]);
    assert_eq!(output.status.code(), Some(2));

    let output = run(&["bogus-subcommand"]);
    assert_eq!(output.status.code(), Some(2));
}
