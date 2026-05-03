//! [antibody-exempt: rust/src/runtime/llm_dispatcher.rs — kernel-floor
//!  LLM dispatcher port (Phase 2 i221) ; parallels existing kernel-floor
//!  runtime markers on adapter_io.rs / shell_dispatcher.rs / adapter_llm.rs.
//!  Retires when the LLM dispatch becomes bluebook-driven via :llm
//!  hecksagon adapters resolved at runtime + a dedicated dispatcher
//!  bluebook (filed as follow-up).]
//!
//! LlmDispatcher — Rust port of ruby/hecks/runtime/llm_dispatcher.rb
//!
//! Takes a hecksagon `adapter :llm` declaration plus runtime context
//! (current AggregateState + dispatch attrs), substitutes the prompt
//! template, resolves the backend provider, calls it, and packages
//! the response into an `LlmResult` ready for the Runtime to dispatch
//! into `response_into_target` with `response_into_attr` set to the
//! returned text.
//!
//! Phase 2 scope vs Ruby :
//!
//!   - The Ruby dispatcher carries Spend / CircuitBreaker / Logger
//!     ports (i23 §4 gating). The Rust port omits them — the runtime
//!     budget surface lives in Ruby until the Rust caller (hecks-life)
//!     grows a budget store.
//!   - Provider resolution mirrors the Ruby form : an explicit
//!     `providers` map wins ; otherwise the default `:test` provider
//!     applies for the `:test` backend ; otherwise `Skipped(provider_unavailable)`.
//!   - Backends recognized : `test`, `claude`, `ollama`, `fixture`
//!     (alias of `test` per the Ruby spec's runtime_llm_spec).

use super::AggregateState;
use super::llm_providers::{LlmError, LlmProvider, LlmProviderResult, TestProvider};
use crate::hecksagon_ir::LlmAdapter;
use std::collections::HashMap;

/// Successful dispatch — the substituted prompt + provider response.
/// Mirrors `LlmDispatcher::Result` in the Ruby surface.
#[derive(Debug, Clone)]
pub struct LlmResult {
    pub adapter_name: String,
    pub prompt: String,
    pub response_text: String,
    pub provider: String,
    pub model_used: String,
    pub tokens_in: u64,
    pub tokens_out: u64,
}

/// Returned (not raised) when the dispatcher refuses the call before
/// the provider invocation : provider unavailable, missing template,
/// etc. Mirrors `LlmDispatcher::Skipped` in Ruby.
#[derive(Debug, Clone)]
pub struct LlmSkipped {
    pub adapter_name: String,
    pub reason: String,
    pub details: String,
}

/// Dispatcher outcome — either Completed (response in hand) or
/// Skipped (gated, no provider call).
#[derive(Debug, Clone)]
pub enum LlmOutcome {
    Completed(LlmResult),
    Skipped(LlmSkipped),
}

impl LlmOutcome {
    pub fn is_completed(&self) -> bool {
        matches!(self, LlmOutcome::Completed(_))
    }
    pub fn into_result(self) -> Option<LlmResult> {
        match self {
            LlmOutcome::Completed(r) => Some(r),
            LlmOutcome::Skipped(_)   => None,
        }
    }
}

const DEFAULT_BACKEND: &str = "test";

/// Dispatch an `:llm` adapter through the gated pipeline.
///
/// `adapter` — the parsed hecksagon declaration.
/// `state` — the upstream aggregate's state (placeholders read from
/// `state.fields` when not in `attrs`).
/// `attrs` — the dispatch attrs (placeholder values, kwarg-style).
/// `providers` — backend name → provider instance ; when None, the
/// default registry applies (`:test` only ; claude/ollama require
/// explicit registration so the dispatcher can never silently shell
/// out from a unit test).
pub fn call(
    adapter: &LlmAdapter,
    state: Option<&AggregateState>,
    attrs: &HashMap<String, String>,
    providers: Option<&HashMap<String, Box<dyn LlmProvider>>>,
) -> LlmOutcome {
    let backend = adapter.backend.clone()
        .unwrap_or_else(|| DEFAULT_BACKEND.to_string());
    // Phase 1 alias — the runtime_llm_spec uses `backend: :fixture` for
    // the test path. Treat `fixture` as `test` so existing fixtures
    // wire through unchanged.
    let backend = if backend == "fixture" { "test".to_string() } else { backend };

    let debug_llm = std::env::var("HECKS_DEBUG_LLM").is_ok();
    if debug_llm {
        eprintln!("[llm:debug] call adapter={} backend={} provider_registered={}",
            adapter.name, backend,
            providers.map(|m| m.contains_key(&backend)).unwrap_or(false));
    }

    let prompt = super::prompt_scaffolder::substitute(
        &adapter.prompt_template, attrs, state,
    );
    if debug_llm {
        eprintln!("[llm:debug] prompt_first_80={}", prompt.chars().take(80).collect::<String>());
    }

    // Resolve provider. Owned (default) and borrowed (explicit map)
    // sources branch — both invoke through the trait.
    let result: Result<LlmProviderResult, LlmError> = match providers
        .and_then(|m| m.get(&backend))
    {
        Some(p) => p.invoke(
            &prompt,
            adapter.model.as_deref().unwrap_or(""),
            adapter.max_tokens.unwrap_or(0),
        ),
        None => {
            if backend == "test" && providers.is_none() {
                let default_provider = TestProvider::new(HashMap::new());
                default_provider.invoke(
                    &prompt,
                    adapter.model.as_deref().unwrap_or(""),
                    adapter.max_tokens.unwrap_or(0),
                )
            } else {
                return LlmOutcome::Skipped(LlmSkipped {
                    adapter_name: adapter.name.clone(),
                    reason: "provider_unavailable".into(),
                    details: format!("backend={}", backend),
                });
            }
        }
    };

    let debug_llm = std::env::var("HECKS_DEBUG_LLM").is_ok();
    match result {
        Ok(pres) => {
            if debug_llm {
                eprintln!("[llm:debug] Completed adapter={} response_first_80={}",
                    adapter.name, pres.response_text.chars().take(80).collect::<String>());
            }
            LlmOutcome::Completed(LlmResult {
                adapter_name: adapter.name.clone(),
                prompt,
                response_text: pres.response_text,
                provider: backend,
                model_used: pres.model_used,
                tokens_in: pres.tokens_in,
                tokens_out: pres.tokens_out,
            })
        },
        Err(LlmError::Unavailable { reason, .. }) => {
            if debug_llm { eprintln!("[llm:debug] Skipped Unavailable adapter={} reason={}", adapter.name, reason); }
            LlmOutcome::Skipped(LlmSkipped {
                adapter_name: adapter.name.clone(),
                reason: "provider_unavailable".into(),
                details: reason,
            })
        },
        Err(LlmError::FixtureMissing { digest }) => {
            if debug_llm { eprintln!("[llm:debug] Skipped FixtureMissing adapter={} sha256={}", adapter.name, digest); }
            LlmOutcome::Skipped(LlmSkipped {
                adapter_name: adapter.name.clone(),
                reason: "fixture_missing".into(),
                details: format!("sha256={}", digest),
            })
        },
        Err(LlmError::Transport { message, .. }) => {
            if debug_llm { eprintln!("[llm:debug] Skipped Transport adapter={} message={}", adapter.name, message); }
            LlmOutcome::Skipped(LlmSkipped {
                adapter_name: adapter.name.clone(),
                reason: "transport_error".into(),
                details: message,
            })
        },
    }
}

/// Helper : split `response_into_target` ("Aggregate.Command") into
/// (aggregate, command). Returns None when the field is missing or
/// malformed (the dispatcher tolerates partial declarations — they
/// simply don't trigger a downstream cascade).
pub fn split_target(target: &str) -> Option<(String, String)> {
    let mut parts = target.splitn(2, '.');
    let agg = parts.next()?.trim();
    let cmd = parts.next()?.trim();
    if agg.is_empty() || cmd.is_empty() { return None; }
    Some((agg.to_string(), cmd.to_string()))
}
