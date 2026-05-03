//! [antibody-exempt: rust/src/runtime/llm_providers/mod.rs — kernel-floor
//!  LLM dispatcher port (Phase 2 i221) ; parallels existing kernel-floor
//!  runtime markers on adapter_io.rs / shell_dispatcher.rs / adapter_llm.rs.
//!  Retires when the LLM dispatch becomes bluebook-driven via :llm
//!  hecksagon adapters resolved at runtime + a dedicated dispatcher
//!  bluebook (filed as follow-up).]
//!
//! LLM provider namespace — Rust port of ruby/hecks/runtime/llm_providers.
//!
//! Every provider implements `LlmProvider` (the trait below) and returns
//! `LlmProviderResult` on success. Three concrete backends ship with the
//! crate :
//!
//!   `:test`     — in-memory fixture-backed (deterministic ; CI default)
//!   `:claude`   — subprocess to the local `claude` CLI binary
//!   `:ollama`   — HTTP POST to a local/remote Ollama daemon
//!
//! Provider parity with the Ruby surface is intentionally narrow : only
//! `invoke` is required (no boot probe in Rust ; the dispatcher gates on
//! provider presence + transport errors). Streaming is not supported in
//! this port — the cascade dispatch that lands the response is single-
//! shot, so streaming would only matter for UI surfaces that don't yet
//! exist in the Rust path.
//!
//! Mirrors:
//!   ruby/hecks/runtime/llm_providers.rb              → mod.rs (this file)
//!   ruby/hecks/runtime/llm_providers/test_provider.rb → test.rs
//!   ruby/hecks/runtime/llm_providers/claude_provider.rb → claude.rs
//!   ruby/hecks/runtime/llm_providers/ollama_provider.rb → ollama.rs

pub mod test;
pub mod claude;
pub mod ollama;

pub use test::TestProvider;
pub use claude::ClaudeProvider;
pub use ollama::OllamaProvider;

use std::collections::HashMap;

/// Successful invocation. `response_text` is what gets routed into
/// `response_into_target` ; the rest are telemetry surfaced to spend /
/// breaker / logger ports the dispatcher will eventually carry.
#[derive(Debug, Clone)]
pub struct LlmProviderResult {
    pub response_text: String,
    pub tokens_in: u64,
    pub tokens_out: u64,
    pub model_used: String,
}

/// Transport / fixture / shape errors raised by a provider. The
/// dispatcher converts these into either a `Skipped` (when the provider
/// is unavailable) or propagates the error upward.
#[derive(Debug, Clone)]
pub enum LlmError {
    /// A fixture provider had no entry for the prompt SHA. Carries the
    /// digest so the caller can capture / debug.
    FixtureMissing { digest: String },
    /// The CLI / HTTP transport failed (process exit, non-200, IO).
    Transport { backend: String, message: String },
    /// Provider was probed degraded — boot failed or env missing.
    Unavailable { backend: String, reason: String },
}

impl std::fmt::Display for LlmError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LlmError::FixtureMissing { digest } =>
                write!(f, "test provider: no fixture for prompt sha256={}", digest),
            LlmError::Transport { backend, message } =>
                write!(f, "{} transport error: {}", backend, message),
            LlmError::Unavailable { backend, reason } =>
                write!(f, "{} provider unavailable: {}", backend, reason),
        }
    }
}

/// Common shape every backend exposes. Trait objects are the dispatch
/// surface : the Runtime carries `HashMap<String, Box<dyn LlmProvider>>`
/// keyed by backend name (`"test"`, `"claude"`, `"ollama"`).
pub trait LlmProvider: Send + Sync {
    /// @param prompt        the substituted prompt (placeholders already filled)
    /// @param model         the model id (claude-sonnet-4, llama3, etc.)
    /// @param max_tokens    the budget hint
    fn invoke(
        &self,
        prompt: &str,
        model: &str,
        max_tokens: u64,
    ) -> Result<LlmProviderResult, LlmError>;
}

/// Default registry — `:test` always present (in-memory, no network).
/// `:claude` and `:ollama` are added when their env / binaries are
/// available ; otherwise dispatch lands in the `provider_unavailable`
/// skipped path. The Ruby side calls this "boot probe" ; the Rust side
/// just attempts the invocation and surfaces transport errors.
pub fn default_registry() -> HashMap<String, Box<dyn LlmProvider>> {
    let mut reg: HashMap<String, Box<dyn LlmProvider>> = HashMap::new();
    reg.insert("test".to_string(), Box::new(TestProvider::new(HashMap::new())));
    reg.insert("claude".to_string(), Box::new(ClaudeProvider::new()));
    reg.insert("ollama".to_string(), Box::new(OllamaProvider::new("http://localhost:11434")));
    reg
}
