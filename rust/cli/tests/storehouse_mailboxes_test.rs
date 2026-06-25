//! `storehouse mailboxes` CLI integration test
//! (sprint 14 — story `storehouse-actors-debug-command`).
//!
//! Shells out to the built `storehouse` binary, runs each verb against
//! the deterministic 3-mailbox fixture, and asserts the output shape :
//!   - `list --fixture` lists three rows with the expected statuses
//!   - `poisoned --fixture` filters to the single poisoned mailbox
//!   - `show Sprint running --fixture` renders the per-mailbox detail
//!   - `list --json --fixture` emits a stable JSON array of summaries
//!
//! Task #08 from the story plan : "Behavior fixture : spawn 3 mailboxes,
//! run storehouse mailboxes list, verify output shape."
//!
//! Same CARGO_BIN_EXE_storehouse + std::process::Command idiom the
//! existing `duplicate_policy_validator_test.rs` uses for sibling CLI
//! integration coverage.

use std::process::Command;

fn run(args: &[&str]) -> (i32, String, String) {
    let bin = env!("CARGO_BIN_EXE_storehouse");
    let out = Command::new(bin)
        .args(args)
        .output()
        .expect("failed to invoke storehouse");
    let code = out.status.code().unwrap_or(-1);
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    (code, stdout, stderr)
}

#[test]
fn mailboxes_list_fixture_renders_three_mailboxes() {
    let (code, stdout, stderr) = run(&["mailboxes", "list", "--fixture"]);
    assert_eq!(code, 0, "mailboxes list --fixture must exit 0 ; stderr: {}", stderr);
    assert!(stdout.contains("TYPE"), "table header missing : {}", stdout);
    assert!(stdout.contains("idle"), "idle mailbox row missing : {}", stdout);
    assert!(stdout.contains("running"), "running mailbox row missing : {}", stdout);
    assert!(stdout.contains("poisoned"), "poisoned mailbox row missing : {}", stdout);
    assert!(stdout.contains("3 mailbox(es)"),
        "footer must report mailbox count : {}", stdout);
}

#[test]
fn mailboxes_poisoned_filters_to_one_row() {
    let (code, stdout, _) = run(&["mailboxes", "poisoned", "--fixture"]);
    assert_eq!(code, 0);
    assert!(stdout.contains("poisoned"),
        "poisoned status must appear : {}", stdout);
    // The fixture has exactly ONE poisoned mailbox ; the footer reflects it.
    assert!(stdout.contains("1 mailbox(es) — 1 poisoned"),
        "footer must report 1 mailbox / 1 poisoned : {}", stdout);
    // No idle row — filter applied.
    assert!(!stdout.contains(" idle "), "idle row must not appear under poisoned filter : {}", stdout);
}

#[test]
fn mailboxes_show_renders_detail_for_known_mailbox() {
    let (code, stdout, _) = run(&["mailboxes", "show", "Sprint", "running", "--fixture"]);
    assert_eq!(code, 0);
    assert!(stdout.contains("address"), "show output missing address line : {}", stdout);
    assert!(stdout.contains("queue_depth"), "show output missing queue_depth : {}", stdout);
    assert!(stdout.contains("events_processed"), "show output missing events_processed : {}", stdout);
    assert!(stdout.contains("status"), "show output missing status : {}", stdout);
}

#[test]
fn mailboxes_show_unknown_address_exits_nonzero() {
    let (code, _stdout, _stderr) = run(&["mailboxes", "show", "Sprint", "ghost", "--fixture"]);
    assert_ne!(code, 0, "unknown address must exit non-zero");
}

#[test]
fn mailboxes_list_json_emits_array_with_three_rows() {
    let (code, stdout, _) = run(&["mailboxes", "list", "--json", "--fixture"]);
    assert_eq!(code, 0);
    let value: serde_json::Value = serde_json::from_str(stdout.trim())
        .expect("--json output must parse as JSON");
    let arr = value.as_array().expect("--json must emit a JSON array");
    assert_eq!(arr.len(), 3, "fixture has 3 mailboxes");
    // Each row carries every documented axis.
    for row in arr {
        assert!(row.get("type").is_some(),     "type missing : {}", row);
        assert!(row.get("id").is_some(),       "id missing : {}", row);
        assert!(row.get("status").is_some(),   "status missing : {}", row);
        assert!(row.get("queue_depth").is_some(),     "queue_depth missing : {}", row);
        assert!(row.get("events_processed").is_some(), "events_processed missing : {}", row);
        assert!(row.get("dropped_duplicates").is_some(), "dropped_duplicates missing : {}", row);
        assert!(row.get("last_error").is_some(), "last_error key missing : {}", row);
    }
}

#[test]
fn mailboxes_advertised_in_top_level_help() {
    // `storehouse` with no args triggers print_usage on stderr (binary
    // invoked as plain `storehouse` — the named-being branch only fires
    // when argv[0] is `miette`/`summer`).
    let (_, _, stderr) = run(&[]);
    let stderr_lower = stderr.to_lowercase();
    assert!(
        stderr_lower.contains("mailboxes")
            && stderr_lower.contains("inspect the actor model"),
        "top-level help must advertise the new mailboxes subcommand : {}", stderr);
}

#[test]
fn legacy_actors_subcommand_is_unknown() {
    // The retired `storehouse actors` CLI must fail with an explicit
    // `Unknown command: actors` and point users at the new verb. The
    // rename is a hard switch, not a deprecated alias — main.rs has an
    // explicit reject arm so the error message is friendly instead of
    // the generic "Cannot read list" fallthrough.
    let (code, _stdout, stderr) = run(&["actors", "list"]);
    assert_ne!(code, 0, "`storehouse actors` must NOT be a recognised subcommand any more");
    assert!(stderr.contains("Unknown command"),
        "stderr must say `Unknown command` : {}", stderr);
    assert!(stderr.contains("actors") && stderr.contains("mailboxes"),
        "reject message must point at the new name : {}", stderr);
}
