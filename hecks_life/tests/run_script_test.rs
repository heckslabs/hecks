//! Integration tests for the `hecks-life run` script-mode subcommand.
//!
//! Builds a tempdir with a bluebook + companion hecksagon, invokes
//! hecks_life::run::run_script, and asserts the right exit code.

use hecks_life::run::{self, ExitKind};

fn tempdir_with(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("hecks-run-test-{}-{}", name, std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn missing_path_is_parse_failure() {
    let args = vec!["hecks-life".into(), "run".into()];
    assert_eq!(run::run_script(&args), ExitKind::ParseFailure.code());
}

#[test]
fn unreadable_path_is_parse_failure() {
    let args = vec!["hecks-life".into(), "run".into(), "/does/not/exist.bluebook".into()];
    assert_eq!(run::run_script(&args), ExitKind::ParseFailure.code());
}

#[test]
fn bluebook_without_entrypoint_is_guard_failure() {
    let dir = tempdir_with("noentry");
    let bb = dir.join("x.bluebook");
    std::fs::write(&bb, "Hecks.bluebook \"Silent\" do\n  aggregate \"Thing\" do\n    command \"DoIt\"\n  end\nend\n").unwrap();
    let args = vec!["hecks-life".into(), "run".into(), bb.to_string_lossy().into()];
    assert_eq!(run::run_script(&args), ExitKind::GuardFailure.code());
}

#[test]
fn unknown_entrypoint_is_command_not_found() {
    let dir = tempdir_with("badentry");
    let bb = dir.join("x.bluebook");
    std::fs::write(&bb, "Hecks.bluebook \"BadEntry\" do\n  entrypoint \"NoSuchCommand\"\n  aggregate \"Thing\" do\n    command \"DoIt\"\n  end\nend\n").unwrap();
    let args = vec!["hecks-life".into(), "run".into(), bb.to_string_lossy().into()];
    assert_eq!(run::run_script(&args), ExitKind::CommandNotFound.code());
}

#[test]
fn valid_script_exits_zero() {
    let dir = tempdir_with("happy");
    let bb = dir.join("x.bluebook");
    std::fs::write(&bb, "#!/usr/bin/env hecks-life run\nHecks.bluebook \"Happy\" do\n  entrypoint \"DoIt\"\n  aggregate \"Thing\" do\n    command \"DoIt\"\n  end\nend\n").unwrap();
    let args = vec!["hecks-life".into(), "run".into(), bb.to_string_lossy().into()];
    assert_eq!(run::run_script(&args), ExitKind::Ok.code());
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
