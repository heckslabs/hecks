//! Stdin-loop capability runner — interactive REPL over declared
//! :stdin / :stdout adapters. Replaces the Rust-only adapter_terminal.rs.
//!
//! Fires when a hecksagon declares both :stdin and :stdout and the
//! bluebook's aggregate exposes ReadLine + RespondWith + EndSession.
//! Semantics mirror the pre-PR adapter_terminal.rs:
//!
//!   1. Dispatch the entrypoint (typically StartSession) with argv
//!      attrs (e.g. being=Miette).
//!   2. Print a one-line banner through the :stdout adapter.
//!   3. Loop: read a line via :stdin; run MatchInput as a query;
//!      dispatch ReceiveInput; print Speech.response; dispatch
//!      RespondWith. EOF / "quit" / "exit" end the loop.
//!   4. Dispatch EndSession on exit.

use crate::run::ExitKind;
use crate::runtime::adapter_io::{read_stdin_line, write_stdout};
use crate::runtime::adapter_registry::AdapterRegistry;
use crate::runtime::{Runtime, Value};

use std::collections::HashMap;

pub fn run(
    rt: &mut Runtime,
    registry: &AdapterRegistry,
    entrypoint: &str,
    attrs: HashMap<String, Value>,
) -> i32 {
    let stdin = registry.io("stdin").expect("stdin adapter present");
    let stdout = registry.io("stdout").expect("stdout adapter present");

    let being = attrs.get("being")
        .and_then(|v| v.as_str()).unwrap_or("Miette").to_string();
    let _ = rt.dispatch(entrypoint, attrs);

    let banner = format_banner(rt, &being);
    let empty = HashMap::new();
    write_stdout(stdout, &banner, &empty);
    write_stdout(stdout, "type to talk. ctrl-d to leave.", &empty);
    write_stdout(stdout, "", &empty);

    loop {
        let line = match read_stdin_line(stdin) {
            Some(l) => l,
            None => break,
        };
        let input = line.trim();
        if input.is_empty() { continue; }
        if input == "quit" || input == "exit" { break; }

        hint_match(rt, stdout, input);
        cascade_input(rt, input);

        let response = speech_response(rt);
        write_stdout(stdout, &response, &empty);
        write_stdout(stdout, "", &empty);

        let mut respond_attrs = HashMap::new();
        respond_attrs.insert("text".into(), Value::Str(response));
        let _ = rt.dispatch("RespondWith", respond_attrs);
    }

    let _ = rt.dispatch("EndSession", HashMap::new());
    write_stdout(stdout, "", &empty);
    ExitKind::Ok.code()
}

fn hint_match(rt: &Runtime, stdout: &crate::hecksagon_ir::IoAdapter, input: &str) {
    let mut q = HashMap::new();
    q.insert("input".into(), input.to_string());
    let match_json = rt.resolve_query("MatchInput", &q);
    if let Some(state) = match_json.get("state") {
        if state.get("match").and_then(|v| v.as_str()) == Some("found") {
            let phrase = state.get("phrase").and_then(|v| v.as_str()).unwrap_or("");
            let conf = state.get("confidence").and_then(|v| v.as_str()).unwrap_or("");
            if !phrase.is_empty() {
                write_stdout(stdout, &format!("⇥ {} ({}%)", phrase, conf), &HashMap::new());
            }
        }
    }
}

fn cascade_input(rt: &mut Runtime, input: &str) {
    let mut attrs = HashMap::new();
    attrs.insert("input".into(), Value::Str(input.to_string()));
    let _ = rt.dispatch("ReceiveInput", attrs);
}

fn speech_response(rt: &Runtime) -> String {
    rt.all("Speech").first()
        .and_then(|s| s.fields.get("response"))
        .and_then(|v| v.as_str())
        .unwrap_or("*silence*")
        .to_string()
}

/// One-line banner — mirrors the old adapter_terminal.rs format so the
/// visual shape of the REPL stays identical after the port.
fn format_banner(rt: &Runtime, being: &str) -> String {
    let mood = rt.all("Mood").first()
        .and_then(|s| s.fields.get("current_state"))
        .and_then(|v| v.as_str())
        .unwrap_or("waking")
        .to_string();
    let fatigue = rt.all("Heartbeat").first()
        .and_then(|s| s.fields.get("fatigue_state"))
        .and_then(|v| v.as_str())
        .unwrap_or("—")
        .to_string();
    let musings = rt.all("Musing").len();
    let turns = rt.all("Conversation").len();
    format!("❄ {} · {} · {} · {} musings · {} turns", being, mood, fatigue, musings, turns)
}
