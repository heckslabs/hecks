//! LLM Adapter — driven adapter for language inference
//!
//! Resolves on an aggregate with `:input` / `:response` fields after
//! dispatch. Two backends :
//!
//!   ollama (default) — the long-standing conversational path. Calls
//!                      `<url>/api/generate` with a fixed "You are
//!                      Miette" prompt prefix ; uses the `/no_think`
//!                      short-response preamble. Config is (model, url)
//!                      and typically comes from a `.world` file's
//!                      `ollama { model: …, url: … }` block.
//!
//!   claude — free-form prompt path for dream production and other
//!            non-conversational uses. Calls the local `claude` binary
//!            (CLAUDE_BIN env var, default /Users/christopheryoung/
//!            .local/bin/claude) with `-p <input>`. The aggregate's
//!            `:input` is used VERBATIM as the prompt — no Miette
//!            wrapper, no prefix — so the bluebook can author the
//!            full introspective dream prompt in French and have it
//!            passed through unchanged.
//!
//! Backend selection :
//!   In-memory adapter (no config)  → no resolve ; fixtures handle it
//!   Config ("ollama", model, url)  → ollama backend
//!   Config ("claude", _, _)        → claude backend
//!
//! The extension was added for Phase F-8 (dream branch as domain),
//! so the rem_branch shell script can retire and dream production
//! runs declaratively from a bluebook + hecksagon pair.

use super::{AggregateState, Value, Repository};

/// Backend selector carried alongside the (model, url) tuple when
/// resolving. Kept as &str so the CLI can pass configuration derived
/// from the hecksagon without introducing a shared enum across crates.
pub type LlmConfig<'a> = (&'a str, &'a str, &'a str); // (backend, model, url)

/// Resolve the LLM adapter on an aggregate after dispatch.
/// If the aggregate has :input/:response and config is provided, call
/// the configured backend. Three-tuple (backend, model, url) ; for
/// claude, model and url are ignored.
///
/// `aggregate` and `command` carry the originating dispatch context
/// so the response writeback persists with `WriteContext::Dispatch`
/// instead of `OutOfBand` — the writeback IS the tail of the original
/// command's effect (its `:response` mutation), so the audit log
/// records it under the same dispatch banner the runtime already wrote
/// the rest of the state under.
pub fn resolve(
    repo: &mut Repository,
    state: &AggregateState,
    config: Option<LlmConfig<'_>>,
    aggregate: &str,
    command: &str,
) {
    // Only act on aggregates with input field set
    let input = match state.fields.get("input") {
        Some(Value::Str(s)) if !s.is_empty() && s != "null" => s.clone(),
        _ => return,
    };

    // No config = in-memory adapter (fixtures handle it)
    let (backend, model, url) = match config {
        Some(c) => c,
        None => return,
    };

    let resp = match backend {
        "claude" => call_claude(&input),
        _        => call_ollama(url, model, &input),
    };

    if let Some(r) = resp {
        let mut updated = state.clone();
        updated.set("response", Value::Str(r));
        repo.save(updated, crate::heki::WriteContext::Dispatch {
            aggregate, command,
        });
    }
}

/// Back-compat two-tuple shim — existing ollama callers in main.rs
/// pass (model, url). This forwards to `resolve` with backend set to
/// "ollama".
pub fn resolve_ollama(
    repo: &mut Repository,
    state: &AggregateState,
    config: Option<(&str, &str)>,
    aggregate: &str,
    command: &str,
) {
    let triple = config.map(|(m, u)| ("ollama", m, u));
    resolve(repo, state, triple, aggregate, command);
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

/// Call the local `claude` binary with `-p <input>` and capture stdout.
/// No prompt wrapper — the input is the full prompt, verbatim. Used
/// for free-form generation (dream production, translation) where the
/// bluebook owns the prompt text.
///
/// Timeout: 20s. Output is trimmed ; blank / too-short responses are
/// treated as failure so the caller can fall back gracefully.
fn call_claude(input: &str) -> Option<String> {
    let bin = std::env::var("CLAUDE_BIN")
        .unwrap_or_else(|_| "/Users/christopheryoung/.local/bin/claude".to_string());
    let output = std::process::Command::new("timeout")
        .args(["20", &bin, "-p", input])
        .output().ok()?;
    let text = String::from_utf8(output.stdout).ok()?;
    let collapsed: String = text.split('\n')
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let trimmed = collapsed.trim().to_string();
    if trimmed.len() > 10 && trimmed.len() < 2000 {
        Some(trimmed)
    } else {
        None
    }
}
