//! Rust-native specializer for `storehouse/src/runtime/adapter_llm.rs`.
//!
//! i147 Wave 3-B target — driven LLM adapter (ollama HTTP-POST +
//! claude shell-invoke + dispatcher) regenerated from the
//! `driven_adapter_shape` bluebook + ordered `.rs.frag` snippets.
//!
//! Design — section-as-row, body_kind dispatches emission. The shape
//! declares one `Section` row per ordered code section in the target.
//! Each row's `body_kind` picks the emission template :
//!
//! ```text
//!     verbatim_section — read `snippet_path` raw, emit unchanged.
//!                        Used for the dispatcher (LlmConfig typedef +
//!                        resolve + resolve_ollama back-compat shim).
//!
//!     http_post        — emit a private `fn <fn_name>(url, model,
//!                        input) -> Option<String>` whose body builds
//!                        a JSON request body, shells out to `curl`,
//!                        parses the response, and decodes a field.
//!                        Knobs : url_path, response_field,
//!                        timeout_secs, num_predict, plus the prompt
//!                        prefix read from `snippet_path` (so the
//!                        per-backend prompt wrapper stays editable
//!                        without recompiling the specializer).
//!
//!     shell_invoke     — emit a private `fn <fn_name>(input) ->
//!                        Option<String>` whose body resolves the bin
//!                        via env var, runs `timeout <secs> <bin>
//!                        <flag> input`, collapses stdout, and
//!                        length-checks the result. Knobs : env_var,
//!                        default_bin, flag, timeout_secs, min_len,
//!                        max_len ; the per-backend doc comment block
//!                        comes from `doc_snippet`.
//! ```
//!
//! The two new body_kinds emit different function bodies but the
//! same input → Option<String> signature family, which is what lets
//! the dispatcher route to either via match-on-backend-string.
//!
//! Usage :
//!
//! ```ignore
//!   let rust = adapter_llm::emit(repo_root)?;
//!   print!("{}", rust);
//! ```
//!
//! [antibody-exempt: storehouse/src/specializer/adapter_llm.rs —
//!  i147 Wave 3-B Rust-native specializer for runtime/adapter_llm.rs.
//!  Retires when the specializer itself is regenerated from a
//!  meta-shape (i78).]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::fs;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/driven_adapter_shape/fixtures/driven_adapter_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let sections = util::by_aggregate_sorted(&fixtures, "Section", "order");

    let mut out = String::new();
    out.push_str(HEADER);
    let last = sections.len().saturating_sub(1);
    for (i, sec) in sections.iter().enumerate() {
        let is_last = i == last;
        match util::attr(sec, "body_kind") {
            "verbatim_section" => {
                let snippet_path = repo_root.join(util::attr(sec, "snippet_path"));
                let body = util::read_snippet_raw(&snippet_path)?;
                out.push_str(&body);
            }
            "http_post" => {
                out.push_str(&emit_http_post(repo_root, sec, is_last)?);
            }
            "shell_invoke" => {
                out.push_str(&emit_shell_invoke(repo_root, sec, is_last)?);
            }
            other => {
                return Err(format!("unknown body_kind: {}", other).into());
            }
        }
    }
    Ok(out)
}

/// Emit an HTTP-POST backend function. Reads the prompt prefix
/// verbatim from `snippet_path` and interpolates it (alongside the
/// other knobs) into a fixed Rust template that calls `curl` and
/// decodes one JSON response field.
fn emit_http_post(repo_root: &Path, sec: &Fixture, is_last: bool) -> Result<String, Box<dyn Error>> {
    let fn_name = util::attr(sec, "fn_name");
    let url_path = util::attr(sec, "url_path");
    let response_field = util::attr(sec, "response_field");
    let timeout_secs = util::attr(sec, "timeout_secs");
    let num_predict = util::attr(sec, "num_predict");
    let prefix_path = repo_root.join(util::attr(sec, "snippet_path"));
    let prompt_prefix = fs::read_to_string(&prefix_path)
        .map_err(|e| format!("prompt prefix snippet missing {}: {}", prefix_path.display(), e))?;

    let mut out = String::new();
    out.push_str(&format!("fn {}(url: &str, model: &str, input: &str) -> Option<String> {{\n", fn_name));
    out.push_str("    let prompt = format!(\n");
    out.push_str(&format!("        \"{}{{}}\",\n", prompt_prefix));
    out.push_str("        input\n");
    out.push_str("    );\n");
    out.push_str("    let body = serde_json::json!({\n");
    out.push_str("        \"model\": model, \"prompt\": prompt, \"stream\": false, \"think\": false,\n");
    out.push_str(&format!("        \"options\": {{ \"num_predict\": {} }}\n", num_predict));
    out.push_str("    });\n");
    out.push_str("    let output = std::process::Command::new(\"curl\")\n");
    out.push_str(&format!("        .args([\"-s\", \"-m\", \"{}\",\n", timeout_secs));
    out.push_str(&format!("               &format!(\"{{}}{}\", url),\n", url_path));
    out.push_str("               \"-d\", &body.to_string()])\n");
    out.push_str("        .output().ok()?;\n");
    out.push_str("    let json: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;\n");
    out.push_str(&format!("    json.get(\"{}\")\n", response_field));
    out.push_str("        .and_then(|v| v.as_str())\n");
    out.push_str("        .map(|s| s.trim().to_string())\n");
    out.push_str("        .filter(|s| !s.is_empty())\n");
    out.push_str("}\n");
    if !is_last {
        out.push('\n');
    }
    Ok(out)
}

/// Emit a shell-invoke backend function. Reads the per-backend doc
/// comment block from `doc_snippet` and interpolates the simple knobs
/// (env_var, default_bin, flag, timeout_secs, min_len, max_len) into
/// a fixed Rust template that shells out via `timeout <secs> <bin>
/// <flag> <input>`, collapses stdout, and length-checks the result.
fn emit_shell_invoke(repo_root: &Path, sec: &Fixture, is_last: bool) -> Result<String, Box<dyn Error>> {
    let fn_name = util::attr(sec, "fn_name");
    let env_var = util::attr(sec, "env_var");
    let default_bin = util::attr(sec, "default_bin");
    let flag = util::attr(sec, "flag");
    let timeout_secs = util::attr(sec, "timeout_secs");
    let min_len = util::attr(sec, "min_len");
    let max_len = util::attr(sec, "max_len");
    let doc_path_attr = util::attr(sec, "doc_snippet");

    let mut out = String::new();
    if !doc_path_attr.is_empty() {
        let doc_path = repo_root.join(doc_path_attr);
        let doc = fs::read_to_string(&doc_path)
            .map_err(|e| format!("doc snippet missing {}: {}", doc_path.display(), e))?;
        out.push_str(&doc);
    }
    out.push_str(&format!("fn {}(input: &str) -> Option<String> {{\n", fn_name));
    out.push_str(&format!("    let bin = std::env::var(\"{}\")\n", env_var));
    out.push_str(&format!("        .unwrap_or_else(|_| \"{}\".to_string());\n", default_bin));
    out.push_str("    let output = std::process::Command::new(\"timeout\")\n");
    out.push_str(&format!("        .args([\"{}\", &bin, \"{}\", input])\n", timeout_secs, flag));
    out.push_str("        .output().ok()?;\n");
    out.push_str("    let text = String::from_utf8(output.stdout).ok()?;\n");
    out.push_str("    let collapsed: String = text.split('\\n')\n");
    out.push_str("        .map(str::trim)\n");
    out.push_str("        .filter(|l| !l.is_empty())\n");
    out.push_str("        .collect::<Vec<_>>()\n");
    out.push_str("        .join(\" \");\n");
    out.push_str("    let trimmed = collapsed.trim().to_string();\n");
    out.push_str(&format!("    if trimmed.len() > {} && trimmed.len() < {} {{\n", min_len, max_len));
    out.push_str("        Some(trimmed)\n");
    out.push_str("    } else {\n");
    out.push_str("        None\n");
    out.push_str("    }\n");
    out.push_str("}\n");
    if !is_last {
        out.push('\n');
    }
    Ok(out)
}

const HEADER: &str = r#"//! LLM Adapter — driven adapter for language inference
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

"#;
