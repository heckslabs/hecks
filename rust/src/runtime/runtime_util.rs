//! runtime_util — the shared free-fn utilities every runtime concern leans
//! on : the dispatch-detail JSON projections, live_pids (the ps-probe
//! liveness set shard consolidation trusts), pascal_to_phrase + trigram_sim
//! (breadcrumb phrasing / fuzzy suggestion), strip_quotes_or_colon +
//! binding_command_tail (hecksagon option normalization), and
//! resolve_handler_path. Pure functions — no runtime state.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [antibody-exempt: rust/src/runtime/runtime_util.rs — pure-utility
//!  plumbing (no domain), relocated verbatim from mod.rs blanket.]

use super::*;

/// i697 — serialise dispatch attrs to a compact JSON object string for
/// the rich dispatch-detail block's `args` field. String/Int/Bool map
/// cleanly ; lists/maps/null fall back to their Display form as a string.
pub(super) fn dispatch_detail_args_json(attrs: &HashMap<String, Value>) -> String {
    let mut map = serde_json::Map::new();
    for (k, v) in attrs {
        map.insert(k.clone(), value_to_json(v));
    }
    serde_json::Value::Object(map).to_string()
}

/// i697 — serialise an aggregate's final state to a compact JSON object
/// string for the rich block's `result_state` field.
pub(super) fn dispatch_detail_state_json(state: &AggregateState) -> String {
    let mut map = serde_json::Map::new();
    for (k, v) in &state.fields {
        map.insert(k.clone(), value_to_json(v));
    }
    serde_json::Value::Object(map).to_string()
}


/// The set of live process ids, via one `ps -A -o pid=` probe. Returns None
/// when liveness cannot be TRUSTED (ps failed, or returned an implausibly
/// empty set), so the caller reclaims NOTHING this pass rather than risk
/// deleting a live process's open shard (whose unlinked inode would swallow
/// its future appends). Dependency-free — no libc — : one cheap subprocess per
/// consolidation tick, far cheaper than a kill(2) per shard.
pub(super) fn live_pids() -> Option<std::collections::HashSet<u32>> {
    let out = std::process::Command::new("ps")
        .args(["-A", "-o", "pid="])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let set: std::collections::HashSet<u32> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.trim().parse::<u32>().ok())
        .collect();
    if set.is_empty() {
        None // implausible : treat as failure, reclaim nothing
    } else {
        Some(set)
    }
}



pub(super) fn pascal_to_phrase(name: &str) -> String {
    let mut result = String::new();
    for (i, c) in name.chars().enumerate() {
        if i > 0 && c.is_uppercase() { result.push(' '); }
        result.push(c.to_lowercase().next().unwrap_or(c));
    }
    result
}

pub(super) fn trigram_sim(a: &str, b: &str) -> f64 {
    if a == b { return 1.0; }
    let a_t: Vec<String> = a.chars().collect::<Vec<_>>().windows(3).map(|w| w.iter().collect()).collect();
    let b_t: Vec<String> = b.chars().collect::<Vec<_>>().windows(3).map(|w| w.iter().collect()).collect();
    if a_t.is_empty() || b_t.is_empty() { return 0.0; }
    let matches = a_t.iter().filter(|t| b_t.contains(t)).count();
    (2.0 * matches as f64) / (a_t.len() + b_t.len()) as f64
}

/// i551 — strip the surrounding shape a hecksagon-options value
/// carries from `parse_options`. String literals come through as
/// `"\"Tools.Bash\""` (raw source token, quotes included) ; symbols
/// come through as `":bash"` (leading colon kept). Both forms need
/// to be reduced to their bare identifier before matching against
/// runtime targets / dispatcher tool names. Whitespace is trimmed
/// because parse_options preserves it from the source.
pub(crate) fn strip_quotes_or_colon(raw: &str) -> String {
    let t = raw.trim();
    if t.len() >= 2 && t.starts_with('"') && t.ends_with('"') {
        // Unescape the source-level string escapes (`\"` -> `"`, `\\` -> `\`).
        // Ruby's own string-literal parsing unescapes these before the DSL ever
        // sees the value, so the Rust side must match or an args payload like
        // `"{\"q\":\"{query}\"}"` reaches serde with literal backslashes and
        // fails JSON parsing — the pre-existing drift the :mcp primitive
        // migration surfaced (every escaped-quote args binding silently hit
        // `[mcp:warn] :args is not JSON` before this).
        let inner = &t[1..t.len() - 1];
        let mut out = String::with_capacity(inner.len());
        let mut chars = inner.chars();
        while let Some(c) = chars.next() {
            if c == '\\' {
                match chars.next() {
                    Some('"') => out.push('"'),
                    Some('\\') => out.push('\\'),
                    Some(other) => {
                        out.push('\\');
                        out.push(other);
                    }
                    None => out.push('\\'),
                }
            } else {
                out.push(c);
            }
        }
        return out;
    }
    if let Some(rest) = t.strip_prefix(':') {
        return rest.to_string();
    }
    t.to_string()
}

/// Reduce a hecksagon binding's `command:` ref to its `Aggregate.Command`
/// tail for matching against a dispatched target. A binding may name its
/// command bare (`"ShellTool.Bash"`) or fully qualified
/// (`"Hecks::Framework::Tools::ShellTool.Bash"`) — both must match the same
/// dispatch, which is always built as `aggregate_type.bare_command` (2-seg).
/// Strip any realm prefix (everything up to the last `::`) before comparing ;
/// without this, an FQN-canonicalized binding silently stops matching and the
/// adapter never fires (the bug that bricked the storehouse door, 2026-06-22).
pub(crate) fn binding_command_tail(c: &str) -> &str {
    c.rsplit("::").next().unwrap_or(c)
}

/// i221-B — convert a serde_json::Map into a HashMap<String, Value>
/// for use as `iter_data` in a sweep dispatch. The sweep records come
/// from `resolve_query` which serializes through serde_json ; this
/// brings them back into the runtime's Value enum so `from_iter
/// (:field)` reads land in the right shape.
/// Resolve an adapter's (possibly relative) handler path to a usable one,
/// trying in order : an ABSOLUTE path as-is ; relative to the aggregates_root
/// (`root`) ; relative to the canonical repo root (where framework `tools/` /
/// `examples/` handlers live) ; relative to CWD. Returns the FIRST that exists,
/// else the root-joined form (so a genuinely-missing handler still yields a
/// stable path the caller's `.exists()` check rejects). The effect drain calls
/// this so a repo-relative handler (e.g. the screenshot DiskBuffer at
/// `tools/web_debug/disk-buffer-handler`) resolves even when the served
/// aggregates_root is some other directory.
#[cfg(not(target_arch = "wasm32"))]
pub(super) fn resolve_handler_path(root: &str, handler: &str) -> String {
    if std::path::Path::new(handler).is_absolute() {
        return handler.to_string();
    }
    let mut candidates: Vec<std::path::PathBuf> = Vec::new();
    if !root.is_empty() {
        candidates.push(std::path::Path::new(root).join(handler));
    }
    if let Some(repo) = crate::heki::repo_root() {
        candidates.push(repo.join(handler));
    }
    candidates.push(std::path::PathBuf::from(handler)); // CWD-relative
    for c in &candidates {
        if c.exists() {
            return c.to_string_lossy().into_owned();
        }
    }
    candidates
        .into_iter()
        .next()
        .map(|c| c.to_string_lossy().into_owned())
        .unwrap_or_else(|| handler.to_string())
}

