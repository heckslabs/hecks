//! [antibody-exempt: rust/src/runtime/compute_functions/mod.rs —
//!  kernel-floor compute function registry (i220 sub-gap 5,
//!  compute-adapter-primitive). The registry IS the kernel : individual
//!  function entries (recent_musings.rs, …) are kernel-surface helpers
//!  that read .heki / format strings. Retires when the function library
//!  becomes pluggable through bluebook (option B in the plan ;
//!  deferred to a follow-on).]
//!
//! Compute-function registry — built-in named functions invokable
//! from `:compute` adapters.
//!
//! Option A in the i220 sub-gap 5 plan : Rust ships a small static
//! library of named functions ; adapters reference them by string
//! name. Simpler, well-scoped, easier to test than option B
//! (compositional `function:` spec referencing the existing query DSL
//! — deferred).
//!
//! Adding a function :
//!
//!   1. New file under `compute_functions/<name>.rs` (one fn per file
//!      keeps the line budget honest).
//!   2. `pub mod <name>;` here.
//!   3. New arm in `invoke()` matching the registry key string.
//!
//! Registry contract (the `invoke` function below) :
//!
//!   - `function_name`  — the registry key (matches the
//!     hecksagon's `function: "<name>"` field).
//!   - `state`          — the upstream aggregate's state (read-only).
//!   - `attrs`          — the dispatch attrs (kwarg-style, string-shaped).
//!   - `data_dir`       — heki root for functions that read .heki files.
//!
//! Returns `Some(String)` on success ; `None` for unregistered names
//! (the caller — `compute_dispatcher::call` — translates that into a
//! `Skipped(function_unregistered)` outcome).

use super::AggregateState;
use std::collections::HashMap;

pub mod recent_musings;
pub mod aggregate_corpus_window;

/// Registry dispatcher — match the function name and call the
/// corresponding implementation. Adding a function here is the
/// only kernel-surface touchpoint per addition (the dispatcher and
/// adapter shape stay stable).
pub fn invoke(
    function_name: &str,
    state: Option<&AggregateState>,
    attrs: &HashMap<String, String>,
    data_dir: Option<&str>,
) -> Option<String> {
    match function_name {
        "summarize_recent_musings" => Some(
            recent_musings::summarize_recent_musings(state, attrs, data_dir)
        ),
        "aggregate_corpus_window" => Some(
            aggregate_corpus_window::aggregate_corpus_window(state, attrs, data_dir)
        ),
        _ => None,
    }
}

/// Test helper — returns the list of registered function names.
/// Useful for cross-validating that a hecksagon's declared
/// `function:` strings all resolve. Production callers invoke
/// directly through `invoke()`.
#[cfg(test)]
pub fn registered_names() -> Vec<&'static str> {
    vec!["summarize_recent_musings", "aggregate_corpus_window"]
}
