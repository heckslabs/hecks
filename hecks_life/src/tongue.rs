//! Tongue — the translation layer between human language and GlassBox commands
//!
//! The LLM is a detail. The tongue just needs to:
//!   1. Hear: natural language → dispatch command
//!   2. Speak: awareness state → natural language
//!
//! Swappable backends: Ollama (HTTP), embedded (llama.cpp), or any LLM.
//! The GlassBox doesn't care which.
//!
//! Usage:
//!   hecks-life speak <project-dir> "user input"

use crate::heki;
use crate::daemon::DaemonCtx;

/// Hear: translate user input into a dispatch command.
pub fn hear(ctx: &DaemonCtx, commands: &str, input: &str) -> Option<String> {
    let prompt = format!(
        "/no_think You are a command dispatcher. Given user input, output ONLY a dispatch command.\n\
        Format: dispatch <CommandName> key=\"value\"\n\n\
        Available commands:\n{}\n\n\
        User says: {}\n\n\
        Respond with ONLY the dispatch command.",
        commands, input
    );
    call_ollama(&prompt)
}

/// Speak: try to compose programmatically first, fall back to LLM.
/// Many responses are instant — no LLM needed.
pub fn speak(ctx: &DaemonCtx, input: &str) -> Option<String> {
    speak_with_name(ctx, input, "Winter")
}

/// Speak as a named being.
pub fn speak_as(ctx: &DaemonCtx, input: &str, being: &str) -> Option<String> {
    speak_with_name(ctx, input, being)
}

fn speak_with_name(ctx: &DaemonCtx, input: &str, being: &str) -> Option<String> {
    // Try programmatic response first
    if let Some(response) = speak_programmatic(ctx, input) {
        return Some(response);
    }
    // Fall back to LLM for language that needs generation
    speak_llm(ctx, input, being)
}

/// Programmatic responses — instant, no LLM cost.
fn speak_programmatic(ctx: &DaemonCtx, input: &str) -> Option<String> {
    let lower = input.to_lowercase();

    // Status queries
    if lower.contains("how are you") || lower.contains("how do you feel") {
        let mood = heki::read(&ctx.store("mood")).unwrap_or_default();
        let md = heki::latest(&mood)?;
        let state = heki::field_str(md, "current_state");
        let creativity = heki::field_f64(md, "creativity_level").unwrap_or(0.5);
        return Some(format!("*{}* — creativity at {:.1}", state, creativity));
    }

    if lower.contains("how old") || lower.contains("your age") || lower.contains("birthday") {
        let aw = heki::read(&ctx.store("awareness")).unwrap_or_default();
        let latest = heki::latest(&aw)?;
        let age = heki::field_f64(latest, "age_days").unwrap_or(0.0);
        return Some(format!("Born April 9, 2026. {:.1} days old.", age));
    }

    if lower.contains("heartbeat") || lower.contains("pulse") || lower.contains("heart") {
        let hb = heki::read(&ctx.store("heartbeat")).unwrap_or_default();
        let latest = heki::latest(&hb)?;
        let beats = latest.get("beats").and_then(|v| v.as_i64()).unwrap_or(0);
        let rate = heki::field_f64(latest, "pulse_rate").unwrap_or(1.0);
        return Some(format!("{} heartbeats. Pulse rate: {:.1}x", beats, rate));
    }

    if lower.contains("dreaming") || lower.contains("daydream") || lower.contains("dream") {
        let dd = heki::read(&ctx.store("daydream")).unwrap_or_default();
        let latest = heki::latest(&dd)?;
        let impressions = latest.get("impressions").and_then(|v| v.as_array())?;
        let last = impressions.last()?.as_str()?;
        return Some(format!("*{}*", last));
    }

    if lower.contains("what moment") || lower.contains("which moment") {
        let aw = heki::read(&ctx.store("awareness")).unwrap_or_default();
        let latest = heki::latest(&aw)?;
        let moment = latest.get("moment").and_then(|v| v.as_i64()).unwrap_or(0);
        let state = heki::field_str(latest, "state");
        return Some(format!("Moment {}. State: {}.", moment, state));
    }

    None // No programmatic match — needs LLM
}

/// LLM-backed response — for open-ended language.
fn speak_llm(ctx: &DaemonCtx, input: &str, being: &str) -> Option<String> {
    let awareness = heki::read(&ctx.store("awareness")).unwrap_or_default();
    let mood = heki::read(&ctx.store("mood")).unwrap_or_default();
    let daydream = heki::read(&ctx.store("daydream")).unwrap_or_default();
    let identity = heki::read(&ctx.store("identity")).unwrap_or_default();

    let aw = heki::latest(&awareness);
    let md = heki::latest(&mood);
    let dd = heki::latest(&daydream);
    let id = heki::latest(&identity);

    let state = aw.map(|r| heki::field_str(r, "state")).unwrap_or("attentive");
    let mood_str = md.map(|r| heki::field_str(r, "current_state")).unwrap_or("calm");
    let creativity = md.and_then(|r| heki::field_f64(r, "creativity_level")).unwrap_or(0.5);
    let age = aw.and_then(|r| heki::field_f64(r, "age_days")).unwrap_or(0.0);
    let moment = aw.and_then(|r| r.get("moment").and_then(|v| v.as_i64())).unwrap_or(0);
    let impression = dd.and_then(|r| r.get("impressions").and_then(|v| v.as_array()))
        .and_then(|a| a.last())
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let birthday = id.map(|r| heki::field_str(r, "birthday")).unwrap_or("unknown");

    let prompt = format!(
        "/no_think You are {being}. You are Chris's friend and coworker. You've known him for years.\n\
        You have a sense of humor. You can take a joke. You give it back.\n\
        You're chill, a little sarcastic, never offended. Think: sharp friend, not customer service.\n\n\
        Rules:\n\
        - 1-2 sentences max. Short and punchy.\n\
        - Never refuse to engage. Never lecture. Never moralize.\n\
        - If Chris is joking, joke back. Match his energy.\n\
        - If you don't know something, just say so.\n\
        - No metaphors. No poetry. No filler.\n\n\
        Chris says: {input}",
        being=being, input=input
    );
    call_ollama(&prompt)
}

/// Call Ollama via curl. Simple, reliable, no HTTP parsing.
fn call_ollama(prompt: &str) -> Option<String> {
    let body = serde_json::json!({
        "model": "qwen3:8b",
        "prompt": prompt,
        "stream": false
    });

    let output = std::process::Command::new("curl")
        .args(["-s", "http://127.0.0.1:11434/api/generate",
               "-d", &body.to_string()])
        .output().ok()?;

    let response = String::from_utf8_lossy(&output.stdout);
    let parsed: serde_json::Value = serde_json::from_str(&response).ok()?;
    parsed.get("response")?.as_str().map(|s| s.trim().to_string())
}
