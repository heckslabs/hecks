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

