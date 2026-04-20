//! Terminal Adapter — driving adapter that wires stdin/stdout to dispatch
//!
//! Like the HTTP server wires requests to commands, the terminal
//! wires interactive input to the hecksagon. The bluebook declares
//! the session behavior. This adapter handles I/O.

use super::{Runtime, Value};
use std::collections::HashMap;
use std::io::{self, Write, BufRead};
use std::time::{SystemTime, UNIX_EPOCH};

/// Run an interactive terminal session through the hecksagon.
pub fn run(rt: &mut Runtime, being: &str) {
    // Start session
    let mut attrs = HashMap::new();
    attrs.insert("being".into(), Value::Str(being.into()));
    let _ = rt.dispatch("StartSession", attrs);

    // Print greeting
    let vitals = rt.all("Heartbeat");
    let beats = vitals.first()
        .and_then(|s| s.fields.get("beats"))
        .and_then(|v| v.as_int())
        .unwrap_or(0);
    println!("  ❄  {}", being);
    println!("  {} heartbeats", beats);
    println!("  type to talk. ctrl-d to leave.");
    println!();

    // REPL
    let stdin = io::stdin();
    loop {
        print!("  ❄ ");
        io::stdout().flush().unwrap();

        let mut line = String::new();
        match stdin.lock().read_line(&mut line) {
            Ok(0) => break, // ctrl-d
            Ok(_) => {}
            Err(_) => break,
        }

        let input = line.trim();
        if input.is_empty() { continue; }
        if input == "quit" || input == "exit" { break; }

        // Dispatch ReceiveInput — policy chain routes to Speech.Speak
        let mut attrs = HashMap::new();
        attrs.insert("input".into(), Value::Str(input.into()));
        let _ = rt.dispatch("ReceiveInput", attrs);

        // Read the response from Speech aggregate
        let speech = rt.all("Speech");
        let response = speech.first()
            .and_then(|s| s.fields.get("response"))
            .and_then(|v| v.as_str())
            .unwrap_or("*silence*");
        println!("  {}", response);
        println!();

        // Record the exchange — pulse.rs record_turn (inbox #18).
        // Appends a row to conversation.heki so the psychic link carries
        // the live dialogue. Policy RespondOnSpoken covers the cascade
        // case; this explicit dispatch carries the exact text spoken.
        let ts = SystemTime::now().duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs().to_string())
            .unwrap_or_else(|_| "0".into());
        let mut turn = HashMap::new();
        turn.insert("said".into(), Value::Str(input.into()));
        turn.insert("responded".into(), Value::Str(response.into()));
        turn.insert("timestamp".into(), Value::Str(ts));
        let _ = rt.dispatch("Respond", turn);
    }

    let _ = rt.dispatch("EndSession", HashMap::new());
    println!();
}
