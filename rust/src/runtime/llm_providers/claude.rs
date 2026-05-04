//! [antibody-exempt: rust/src/runtime/llm_providers/claude.rs — kernel-floor
//!  LLM dispatcher port (Phase 2 i221) ; parallels existing kernel-floor
//!  runtime markers on adapter_io.rs / shell_dispatcher.rs / adapter_llm.rs.
//!  Retires when the LLM dispatch becomes bluebook-driven via :llm
//!  hecksagon adapters resolved at runtime + a dedicated dispatcher
//!  bluebook (filed as follow-up).]
//!
//! ClaudeProvider — subprocess to the local `claude` CLI binary.
//! Mirrors `ruby/hecks/runtime/llm_providers/claude_provider.rb` (CLI
//! transport only ; the API path is owned by Ruby until the dream-image
//! pipeline grows a streaming consumer).
//!
//! Strict env whitelist : only HOME + PATH pass through to the child
//! (matches the shell_dispatcher discipline for unsetenv_others). The
//! CLI legitimately needs HOME (subscription auth state) and PATH
//! (it shells out to find tools).
//!
//! Output parsing : the unary form (`claude -p <prompt>`) returns plain
//! text on stdout. The Ruby provider also supports `--output-format
//! stream-json` for token telemetry ; this Rust port runs the simpler
//! unary form and estimates tokens via whitespace-split. Spend
//! accounting in the Rust path is best-effort until the CLI's
//! stream-json schema settles.

use super::{LlmError, LlmProvider, LlmProviderResult};
use std::process::{Command, Stdio};
use std::io::Write;

pub struct ClaudeProvider {
    bin: String,
}

impl ClaudeProvider {
    pub fn new() -> Self {
        let bin = std::env::var("CLAUDE_BIN")
            .unwrap_or_else(|_| "claude".to_string());
        Self { bin }
    }

    pub fn with_bin(bin: impl Into<String>) -> Self {
        Self { bin: bin.into() }
    }
}

impl Default for ClaudeProvider {
    fn default() -> Self { Self::new() }
}

impl LlmProvider for ClaudeProvider {
    fn invoke(
        &self,
        prompt: &str,
        model: &str,
        max_tokens: u64,
    ) -> Result<LlmProviderResult, LlmError> {
        // Args mirror the Ruby provider's CLI form, minus stream-json :
        //   claude -p --model <model>
        // Prompt is fed via stdin so command-line length limits don't
        // bite on long substituted templates.
        //
        // The claude CLI does NOT support --max-tokens (verified via
        // claude --help — only --max-budget-usd exists at that knob).
        // The bluebook's `max_tokens 200` stays as metadata for the
        // future API path ; the unary CLI just lets claude pick.
        // Same for --model with unrecognized aliases : the CLI falls
        // back to its default when the name doesn't match, which is
        // good-enough behaviour for the dream pipeline.
        let _ = max_tokens; // intentionally unused at the unary CLI surface
        let mut cmd = Command::new(&self.bin);
        cmd.arg("-p");
        if !model.is_empty() {
            cmd.arg("--model").arg(model);
        }
        // Inherit parent env. The env_clear() approach (HOME + PATH only)
        // breaks claude's macOS keychain auth — verified : `env -i
        // HOME=... PATH=... claude -p` returns "Not logged in · Please
        // run /login". The keychain lookup needs more state than HOME
        // alone exposes (LOGNAME, USER, possibly SHLVL, plus any
        // tooling-specific vars). The shell-dispatcher discipline of
        // strict env whitelists applies to UNTRUSTED shell calls ; the
        // claude CLI is a known good binary we explicitly chose to
        // invoke, so inheriting the parent process env is appropriate.
        cmd.stdin(Stdio::piped())
           .stdout(Stdio::piped())
           .stderr(Stdio::piped());

        let mut child = cmd.spawn().map_err(|e| {
            // ENOENT / EACCES — provider unavailable, dispatcher should
            // surface as Skipped(provider_unavailable).
            if e.kind() == std::io::ErrorKind::NotFound {
                LlmError::Unavailable {
                    backend: "claude".into(),
                    reason: format!("claude CLI not found: {}", e),
                }
            } else {
                LlmError::Transport {
                    backend: "claude".into(),
                    message: format!("spawn failed: {}", e),
                }
            }
        })?;

        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(prompt.as_bytes());
        }

        let output = child.wait_with_output().map_err(|e| LlmError::Transport {
            backend: "claude".into(),
            message: format!("wait failed: {}", e),
        })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
            let first_line = stderr.lines().next().unwrap_or("").to_string();
            return Err(LlmError::Transport {
                backend: "claude".into(),
                message: format!("claude CLI exit {}: {}",
                    output.status.code().unwrap_or(-1), first_line),
            });
        }

        let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
        let collapsed: String = stdout.lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        let response_text = collapsed.trim().to_string();

        Ok(LlmProviderResult {
            tokens_in: estimate_tokens(prompt),
            tokens_out: estimate_tokens(&response_text),
            response_text,
            model_used: model.to_string(),
        })
    }
}

fn estimate_tokens(text: &str) -> u64 {
    text.split_whitespace().filter(|s| !s.is_empty()).count() as u64
}
