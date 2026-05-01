//! Smoke test for the terminal capability's shape.
//!
//! Just asserts that the shipped bluebook + hecksagon parse to the
//! expected aggregate / command / adapter set. Execution (actually
//! running the REPL) is exercised end-to-end in commit 9.

use hecks_life::{hecksagon_parser, parser, run};
use std::fs;

const BLUEBOOK: &str = "../hecks_conception/capabilities/terminal/terminal.bluebook";
const HECKSAGON: &str = "../hecks_conception/capabilities/terminal/terminal.hecksagon";

#[test]
fn terminal_bluebook_parses_with_session_aggregate() {
    let src = fs::read_to_string(BLUEBOOK).expect("missing terminal.bluebook");
    let domain = parser::parse(&src);
    assert_eq!(domain.name, "Terminal");
    assert_eq!(domain.entrypoint.as_deref(), Some("StartSession"));
    let session = domain.aggregates.iter().find(|a| a.name == "Session")
        .expect("Session aggregate missing");
    let cmds: Vec<&str> = session.commands.iter().map(|c| c.name.as_str()).collect();
    for expected in ["StartSession", "ReadLine", "MatchInput", "RespondWith", "EndSession"] {
        assert!(cmds.contains(&expected), "expected command {}", expected);
    }
}

#[test]
fn terminal_hecksagon_parses_with_stdio_adapters() {
    let src = fs::read_to_string(HECKSAGON).expect("missing terminal.hecksagon");
    let hex = hecksagon_parser::parse(&src);
    assert_eq!(hex.name, "Terminal");
    assert_eq!(hex.persistence.as_deref(), Some("memory"));
    assert!(hex.io_adapter("stdout").is_some(), "stdout adapter missing");
    assert!(hex.io_adapter("stdin").is_some(),  "stdin adapter missing");
    assert!(hex.io_adapter("stderr").is_some(), "stderr adapter missing");
}

#[test]
fn run_script_loader_finds_companion_hecksagon() {
    let (domain, hex) = run::load_script(BLUEBOOK).expect("loader rejected bluebook");
    assert_eq!(domain.name, "Terminal");
    assert_eq!(hex.name, "Terminal");
}
