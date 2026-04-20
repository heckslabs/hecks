//! Terminal Adapter — driving adapter that wires stdin/stdout to dispatch
//!
//! Like the HTTP server wires requests to commands, the terminal
//! wires interactive input to the hecksagon. The bluebook declares
//! the session behavior. This adapter handles I/O.
//!
//! Features (inbox #21 — scoped restoration of the deleted terminal.rs):
//!   * Startup banner — mood + fatigue_state + musings/turns counts
//!   * Greeting pop   — dispatch Greeting.PopGreeting at start, echo text
//!   * MatchInput     — try lexicon match before dispatching ReceiveInput;
//!                      if confidence > 30%, show the match and skip LLM.
//!   * Conversation   — every turn dispatches Respond so conversation.heki
//!                      grows with the live dialogue (record_turn parity).

use super::{Runtime, Value};
use std::collections::HashMap;
use std::io::{self, Write, BufRead};
use std::time::{SystemTime, UNIX_EPOCH};

/// Build the one-line startup banner from the runtime's current state.
fn banner(rt: &Runtime, being: &str) -> String {
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
    format!("{} · {} · {} · {} musings · {} turns", being, mood, fatigue, musings, turns)
}

/// Run an interactive terminal session through the hecksagon.
pub fn run(rt: &mut Runtime, being: &str) {
    // Start session
    let mut attrs = HashMap::new();
    attrs.insert("being".into(), Value::Str(being.into()));
    let _ = rt.dispatch("StartSession", attrs);

    // Banner — the new one-line form with mood + fatigue + counts.
    println!("  ❄ {}", banner(rt, being));

    // Greeting pop — dispatch PopGreeting; if anything came back in the
    // Greeting aggregate's `text` field and it's unserved, echo it. The
    // greeting.sh daemon keeps a warm queue so this is instant language.
    let _ = rt.dispatch("PopGreeting", HashMap::new());
    if let Some(text) = rt.all("Greeting").iter()
        .find(|s| s.fields.get("served").and_then(|v| v.as_str()) == Some("true"))
        .and_then(|s| s.fields.get("text"))
        .and_then(|v| v.as_str())
    {
        if !text.is_empty() { println!("  {}", text); }
    }
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

        // MatchInput first — try a programmatic lexicon match before
        // going through the full ReceiveInput cascade. If confidence is
        // high (>30%, matching the threshold in resolve_query), print a
        // hint line so Miette confirms the recognized phrase. Actual
        // dispatch still happens through ReceiveInput so the cascade
        // fires (tongue, speech, conversation).
        let mut q = HashMap::new();
        q.insert("input".into(), input.to_string());
        let match_json = rt.resolve_query("MatchInput", &q);
        if let Some(state) = match_json.get("state") {
            if state.get("match").and_then(|v| v.as_str()) == Some("found") {
                let phrase = state.get("phrase").and_then(|v| v.as_str()).unwrap_or("");
                let conf   = state.get("confidence").and_then(|v| v.as_str()).unwrap_or("");
                if !phrase.is_empty() { println!("  ⇥ {} ({}%)", phrase, conf); }
            }
        }

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
