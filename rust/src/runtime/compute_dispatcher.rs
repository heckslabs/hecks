//! [antibody-exempt: rust/src/runtime/compute_dispatcher.rs — kernel-floor
//!  compute dispatcher (i220 sub-gap 5, compute-adapter-primitive) ;
//!  parallels rust/src/runtime/llm_dispatcher.rs. Same retirement contract :
//!  retires when the compute adapter family becomes bluebook-driven via
//!  a dedicated dispatcher bluebook.]
//!
//! ComputeDispatcher — sibling of llm_dispatcher.rs for local computation.
//!
//! Where `:llm` adapters substitute a prompt and call out to a model,
//! `:compute` adapters resolve a `function_name` against the
//! `compute_functions` registry and invoke the named function with
//! the upstream aggregate's state + dispatch attrs. The function
//! returns a String which the runtime chains as a `dispatch_cascade`
//! into `response_into_target` carrying `response_into_attr`.
//!
//! Two outcomes mirror the llm_dispatcher shape :
//!
//!   - `Completed(ComputeResult)`  — function ran, response in hand
//!   - `Skipped(ComputeSkipped)`   — registry miss / inert adapter
//!
//! No backend abstraction (the function IS the backend) and no
//! provider registry (the function library lives statically in
//! `compute_functions::registry`). One dispatcher call = one
//! function invocation = one cascade dispatch.

use super::AggregateState;
use super::compute_functions;
use crate::hecksagon_ir::ComputeAdapter;
use std::collections::HashMap;

/// Successful dispatch — the function's return value plus the
/// adapter name (for logging / cascade routing).
#[derive(Debug, Clone)]
pub struct ComputeResult {
    pub adapter_name: String,
    pub function_name: String,
    pub response_text: String,
}

/// Returned (not raised) when the dispatcher refuses the call before
/// the function invocation : function unregistered, malformed adapter,
/// etc. Mirrors `LlmSkipped`.
#[derive(Debug, Clone)]
pub struct ComputeSkipped {
    pub adapter_name: String,
    pub reason: String,
    pub details: String,
}

#[derive(Debug, Clone)]
pub enum ComputeOutcome {
    Completed(ComputeResult),
    Skipped(ComputeSkipped),
}

impl ComputeOutcome {
    pub fn is_completed(&self) -> bool {
        matches!(self, ComputeOutcome::Completed(_))
    }
    pub fn into_result(self) -> Option<ComputeResult> {
        match self {
            ComputeOutcome::Completed(r) => Some(r),
            ComputeOutcome::Skipped(_)   => None,
        }
    }
}

/// Dispatch an `:compute` adapter through the function registry.
///
/// `adapter` — the parsed hecksagon declaration.
/// `state`   — the upstream aggregate's state (functions read field
///             values from here when they need them).
/// `attrs`   — the dispatch attrs (string-shaped, kwarg-style ; same
///             projection the llm dispatcher uses).
/// `data_dir` — heki root so functions that read `.heki` files
///             (summarize_recent_musings reads `musing.heki`) can
///             locate their input.
pub fn call(
    adapter: &ComputeAdapter,
    state: Option<&AggregateState>,
    attrs: &HashMap<String, String>,
    data_dir: Option<&str>,
) -> ComputeOutcome {
    let debug = std::env::var("HECKS_DEBUG").is_ok();
    if debug {
        eprintln!("[compute:debug] call adapter={} function={} state_present={} attrs_len={}",
            adapter.name, adapter.function_name, state.is_some(), attrs.len());
    }

    if adapter.function_name.is_empty() {
        return ComputeOutcome::Skipped(ComputeSkipped {
            adapter_name: adapter.name.clone(),
            reason: "function_unset".into(),
            details: "adapter declared no function: name".into(),
        });
    }

    let outcome = compute_functions::invoke(&adapter.function_name, state, attrs, data_dir);
    match outcome {
        Some(text) => {
            if debug {
                eprintln!("[compute:debug] Completed adapter={} text_first_80={}",
                    adapter.name, text.chars().take(80).collect::<String>());
            }
            ComputeOutcome::Completed(ComputeResult {
                adapter_name: adapter.name.clone(),
                function_name: adapter.function_name.clone(),
                response_text: text,
            })
        }
        None => {
            if debug {
                eprintln!("[compute:debug] Skipped function_unregistered adapter={} function={}",
                    adapter.name, adapter.function_name);
            }
            ComputeOutcome::Skipped(ComputeSkipped {
                adapter_name: adapter.name.clone(),
                reason: "function_unregistered".into(),
                details: format!("function={}", adapter.function_name),
            })
        }
    }
}

/// Helper : split `response_into_target` ("Aggregate.Command") into
/// (aggregate, command). Mirrors `llm_dispatcher::split_target` so
/// the runtime's resolver can route the chain identically across
/// adapter families.
pub fn split_target(target: &str) -> Option<(String, String)> {
    let mut parts = target.splitn(2, '.');
    let agg = parts.next()?.trim();
    let cmd = parts.next()?.trim();
    if agg.is_empty() || cmd.is_empty() { return None; }
    Some((agg.to_string(), cmd.to_string()))
}
