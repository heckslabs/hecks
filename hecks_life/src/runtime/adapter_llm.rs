//! LLM Adapter — driven adapter for language inference
//!
//! Like sqlite for persistence, this adapter resolves LLM inference.
//! Convention: aggregates with :input and :response fields get inference.
//! In-memory: fixtures provide canned responses.
//! Configured: *.world ollama block activates live inference.

use super::{AggregateState, Value, Repository};

/// Resolve the LLM adapter on an aggregate after dispatch.
/// If the aggregate has :input/:response and config is provided, call ollama.
pub fn resolve(
    repo: &mut Repository,
    state: &AggregateState,
    config: Option<(&str, &str)>,
) {
    // Only act on aggregates with input field set
    let input = match state.fields.get("input") {
        Some(Value::Str(s)) if !s.is_empty() && s != "null" => s.clone(),
        _ => return,
    };

    // No config = in-memory adapter (fixtures handle it)
    let (model, url) = match config {
        Some(c) => c,
        None => return,
    };

    if let Some(resp) = call_ollama(url, model, &input) {
        let mut updated = state.clone();
        updated.set("response", Value::Str(resp));
        repo.save(updated);
    }
}

fn call_ollama(url: &str, model: &str, input: &str) -> Option<String> {
    let prompt = format!(
        "/no_think You are Miette. Be concise. 1-2 sentences.\n\nChris says: {}",
        input
    );
    let body = serde_json::json!({
        "model": model, "prompt": prompt, "stream": false, "think": false,
        "options": { "num_predict": 100 }
    });
    let output = std::process::Command::new("curl")
        .args(["-s", "-m", "15",
               &format!("{}/api/generate", url),
               "-d", &body.to_string()])
        .output().ok()?;
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    json.get("response")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}
