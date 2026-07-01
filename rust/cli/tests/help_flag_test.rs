//! Help-flag regression test (DX Tier 0).
//!
//! Locks the contract: `--help` / `-h` / `help` print the command list and exit
//! 0. Before 2026-07-01 they fell through to command dispatch and were treated
//! as an unknown command NAME ("Usage: storehouse --help <bluebook-file-or-dir>",
//! exit 1) — the broken help surface a newcomer hits first. Bare `storehouse`
//! (no command) stays a usage ERROR (exit 1) — that's a distinct case.

use std::process::Command;

fn run(args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_storehouse"))
        .args(args)
        .output()
        .expect("invoke storehouse")
}

fn help_ok(flag: &str) {
    let out = run(&[flag]);
    assert_eq!(out.status.code(), Some(0),
        "`storehouse {}` must exit 0; stdout: {}\nstderr: {}", flag,
        String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    let combined = format!("{}{}",
        String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    assert!(combined.contains("Commands:"),
        "`storehouse {}` should list Commands; got: {}", flag, combined);
    assert!(combined.contains("the Bluebook compiler and runtime"),
        "`storehouse {}` should print the banner; got: {}", flag, combined);
}

#[test]
fn dash_dash_help_prints_commands_and_exits_zero() { help_ok("--help"); }

#[test]
fn dash_h_prints_commands_and_exits_zero() { help_ok("-h"); }

#[test]
fn bare_help_word_prints_commands_and_exits_zero() { help_ok("help"); }

#[test]
fn no_command_is_a_usage_error_exit_1() {
    // Distinct from an explicit help request : no command given is an error.
    let out = run(&[]);
    assert_eq!(out.status.code(), Some(1),
        "bare `storehouse` (no command) must exit 1 (usage error)");
}
