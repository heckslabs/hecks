//! [antibody-exempt: rust/src/runtime/llm_providers/ollama.rs — kernel-floor
//!  LLM dispatcher port (Phase 2 i221) ; parallels existing kernel-floor
//!  runtime markers on adapter_io.rs / shell_dispatcher.rs / adapter_llm.rs.
//!  Retires when the LLM dispatch becomes bluebook-driven via :llm
//!  hecksagon adapters resolved at runtime + a dedicated dispatcher
//!  bluebook (filed as follow-up).]
//!
//! OllamaProvider — POSTs to `<url>/api/generate` via the system curl
//! binary. Mirrors `ruby/hecks/runtime/llm_providers/ollama_provider.rb`
//! (unary path only — no streaming in the Rust port until a streaming
//! consumer surfaces).
//!
//! Curl transport keeps the crate dep-free (no reqwest / hyper / ureq).
//! Same approach the existing `runtime/adapter_llm.rs` already uses
//! for the legacy ollama path.

use super::{LlmError, LlmProvider, LlmProviderResult};
use std::process::Command;

pub struct OllamaProvider {
    url: String,
}

impl OllamaProvider {
    pub fn new(url: impl Into<String>) -> Self {
        Self { url: url.into() }
    }

    pub fn url(&self) -> &str { &self.url }
}

impl Default for OllamaProvider {
    fn default() -> Self { Self::new("http://localhost:11434") }
}

impl LlmProvider for OllamaProvider {
    fn invoke(
        &self,
        prompt: &str,
        model: &str,
        max_tokens: u64,
    ) -> Result<LlmProviderResult, LlmError> {
        let body = serde_json::json!({
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": { "num_predict": max_tokens }
        });
        let endpoint = format!("{}/api/generate", self.url.trim_end_matches('/'));
        let output = Command::new("curl")
            .args([
                "-s", "-S", "-m", "60",
                "-H", "content-type: application/json",
                "-X", "POST",
                "-d", &body.to_string(),
                &endpoint,
            ])
            .output()
            .map_err(|e| LlmError::Transport {
                backend: "ollama".into(),
                message: format!("curl spawn failed: {}", e),
            })?;
        if !output.status.success() {
            return Err(LlmError::Transport {
                backend: "ollama".into(),
                message: format!("curl exit {}: {}",
                    output.status.code().unwrap_or(-1),
                    String::from_utf8_lossy(&output.stderr)),
            });
        }
        let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
        let json: serde_json::Value = serde_json::from_str(&stdout)
            .map_err(|e| LlmError::Transport {
                backend: "ollama".into(),
                message: format!("ollama returned non-JSON: {} (body: {})",
                    e, stdout.chars().take(200).collect::<String>()),
            })?;
        let response_text = json.get("response")
            .and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
        let tokens_in = json.get("prompt_eval_count").and_then(|v| v.as_u64()).unwrap_or(0);
        let tokens_out = json.get("eval_count").and_then(|v| v.as_u64()).unwrap_or(0);
        let model_used = json.get("model")
            .and_then(|v| v.as_str()).unwrap_or(model).to_string();
        Ok(LlmProviderResult {
            response_text, tokens_in, tokens_out, model_used,
        })
    }
}
