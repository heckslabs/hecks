//! [antibody-exempt: rust/src/runtime/mcp_dispatcher/mod.rs —
//!  kernel-floor handler for the `:mcp` hecksagon adapter family
//!  (i593). Implements the `invoke_mcp_tool` behavior_kind declared
//!  in framework/behavior_kinds/invoke_mcp_tool.hecksagon : one
//!  native primitive that opens a stdio MCP session against a named
//!  server, calls a named tool with a JSON arguments object, and
//!  captures the response. Sibling kernel-floor port to
//!  claude_tool_dispatcher / web_tool_dispatcher ; same exemption
//!  pattern, retires when the framework-wide kernel-hook registry
//!  replaces hard-coded handler tables.]
//!
//! McpDispatcher — kernel hook for the :mcp adapter family
//!
//! When a bluebook command dispatches and the matching hecksagon
//! carries an `adapter :mcp` row, the runtime locates the binding,
//! reads its `server`, `tool`, and `args` fields, and calls
//! `dispatch_via_registry` below. The dispatcher :
//!
//!   1. Resolves :server to a spawn command (v1 : :storehouse → node
//!      tooling/storehouse-mcp/src/server.mjs).
//!   2. Substitutes `{attr}` placeholders in :args from the dispatched
//!      command's attribute map.
//!   3. Spawns the server, does the JSON-RPC initialize → notifications/
//!      initialized → tools/call → close dance over stdio.
//!   4. Parses the tools/call response and returns a KernelResult with
//!      the tool's text content + isError flag.
//!
//! Pattern mirrors claude_tool_dispatcher : take the adapter's declared
//! fields + the dispatched command's attrs, execute, return a
//! structured result the Runtime can chain back via the adapter's
//! `result_into` target.
//!
//! ── Scope ──
//!
//! v1 is one-shot per call : each dispatch spawns its own MCP server
//! subprocess and tears it down on completion. Acceptable for the
//! SessionStart case (one call per session) and post-tool-use
//! (one call per tool dispatch). High-rate use cases (statusline
//! polls, every-tick policies) will want a long-lived session ; that
//! is a v2 path with the same field surface, different transport
//! state, filed as a follow-on when it bites.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::Duration;

use crate::runtime::framework_registry::KernelResult;

// ─────────────────────────────────────────────────────────────────────
//  Server registry
// ─────────────────────────────────────────────────────────────────────

/// True when `server` names a registered MCP server. Lets callers
/// (e.g. `Runtime::resolve_mcp_adapters`, i594) validate the binding's
/// `:server` field at dispatch time and emit a warning rather than
/// silently failing when an unregistered server (e.g. `:gmail`,
/// pending i610's bridge) appears. Trims a leading `:` so both
/// `:storehouse` and `storehouse` answer truthy ; matches the same
/// rule `resolve_server_spawn` follows.
pub fn server_is_registered(server: &str) -> bool {
    let name = server.trim_start_matches(':');
    matches!(name, "storehouse")
}

/// Resolve the :server field to a (program, args) spawn pair.
///
/// v1 supports a single value : :storehouse → the local stdio server
/// at tooling/storehouse-mcp/src/server.mjs (relative to the hecks
/// repo root, resolved via the storehouse binary's path).
///
/// Returns `None` if the server name is unknown. Returns `Some(_)`
/// even when the path cannot be resolved — the dispatcher surfaces a
/// readable error on spawn failure rather than failing here.
fn resolve_server_spawn(server: &str) -> Option<(String, Vec<String>)> {
    // Trim a leading `:` so both `:storehouse` and `storehouse` work
    // — hecksagon parsers vary on whether the colon comes through.
    let name = server.trim_start_matches(':');
    match name {
        "storehouse" => {
            let server_path = locate_storehouse_mcp_server();
            Some(("node".to_string(), vec![server_path]))
        }
        _ => None,
    }
}

/// Walk from the current storehouse binary's path up the parent chain
/// looking for `tooling/storehouse-mcp/src/server.mjs`. Mirrors the
/// path-discovery pattern in run_boot/daemons.rs::resolve_body_dir.
/// Returns an empty string if not found ; spawn will fail loudly and
/// the dispatcher will report the error in its KernelResult.
fn locate_storehouse_mcp_server() -> String {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(_) => return String::new(),
    };
    // The storehouse binary typically lives at rust/target/release/storehouse
    // or rust/target/debug/storehouse. Walk up to find the rust/ dir,
    // then sibling tooling/storehouse-mcp/src/server.mjs.
    let mut cur: PathBuf = match exe.parent() {
        Some(p) => p.to_path_buf(),
        None => return String::new(),
    };
    for _ in 0..6 {
        let candidate = cur.join("tooling/storehouse-mcp/src/server.mjs");
        if candidate.is_file() {
            return candidate.to_string_lossy().to_string();
        }
        if !cur.pop() {
            break;
        }
    }
    String::new()
}

// ─────────────────────────────────────────────────────────────────────
//  JSON-RPC over stdio
// ─────────────────────────────────────────────────────────────────────

/// One MCP session. Owns the child process + stdio pipes for its
/// lifetime ; closing drops the child and the pipes.
struct McpSession {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_id: u64,
}

impl McpSession {
    /// Spawn `<program> <args>` with stdin/stdout piped, capture stderr
    /// to null (the server logs there but we don't surface them in v1).
    fn spawn(program: &str, args: &[String]) -> Result<Self, String> {
        let mut cmd = Command::new(program);
        cmd.args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = cmd.spawn().map_err(|e| {
            format!("mcp : spawn '{}' failed : {}", program, e)
        })?;
        let stdin = child.stdin.take().ok_or("mcp : no stdin")?;
        let stdout = BufReader::new(child.stdout.take().ok_or("mcp : no stdout")?);
        Ok(Self { child, stdin, stdout, next_id: 1 })
    }

    /// Send a JSON-RPC message as a single newline-terminated line
    /// (the MCP stdio convention). Returns the id used so the caller
    /// can match the response.
    fn send_request(&mut self, method: &str, params: serde_json::Value) -> Result<u64, String> {
        let id = self.next_id;
        self.next_id += 1;
        let msg = serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        });
        let line = serde_json::to_string(&msg)
            .map_err(|e| format!("mcp : encode {} : {}", method, e))?;
        self.stdin.write_all(line.as_bytes())
            .map_err(|e| format!("mcp : write {} : {}", method, e))?;
        self.stdin.write_all(b"\n")
            .map_err(|e| format!("mcp : write newline : {}", e))?;
        self.stdin.flush().ok();
        Ok(id)
    }

    fn send_notification(&mut self, method: &str, params: serde_json::Value) -> Result<(), String> {
        let msg = serde_json::json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        });
        let line = serde_json::to_string(&msg)
            .map_err(|e| format!("mcp : encode notify {} : {}", method, e))?;
        self.stdin.write_all(line.as_bytes())
            .map_err(|e| format!("mcp : write notify {} : {}", method, e))?;
        self.stdin.write_all(b"\n").ok();
        self.stdin.flush().ok();
        Ok(())
    }

    /// Read JSON-RPC responses line by line until one matches `id`.
    /// Skips server-initiated notifications (no `id` field) and
    /// out-of-order responses (different `id`). Returns the `result`
    /// payload on success, or the JSON-RPC `error` shape on failure.
    fn await_response(&mut self, id: u64) -> Result<serde_json::Value, String> {
        loop {
            let mut line = String::new();
            let n = self.stdout.read_line(&mut line)
                .map_err(|e| format!("mcp : read : {}", e))?;
            if n == 0 {
                return Err("mcp : server closed stdout before responding".into());
            }
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let parsed: serde_json::Value = match serde_json::from_str(trimmed) {
                Ok(v) => v,
                Err(_) => continue, // not JSON ; could be a server log line, skip
            };
            // Notifications carry no id ; skip.
            let msg_id = match parsed.get("id").and_then(|v| v.as_u64()) {
                Some(i) => i,
                None => continue,
            };
            if msg_id != id {
                continue;
            }
            if let Some(err) = parsed.get("error") {
                return Err(format!("mcp : server error : {}", err));
            }
            return Ok(parsed.get("result").cloned()
                .unwrap_or(serde_json::Value::Null));
        }
    }
}

impl Drop for McpSession {
    fn drop(&mut self) {
        // Close stdin so the server's stdio loop terminates cleanly.
        // The child should exit on its own once stdin closes ; we
        // wait briefly then move on. We don't kill — a clean exit is
        // the contract MCP servers follow.
        let _ = self.child.wait();
    }
}

// ─────────────────────────────────────────────────────────────────────
//  The one tool call
// ─────────────────────────────────────────────────────────────────────

/// What `dispatch` produced — the parsed text content from a tools/call
/// response, plus the structured payload and an error marker.
#[derive(Debug, Clone, Default)]
pub struct McpToolResult {
    /// Concatenated `text` content blocks from the MCP response.
    pub text: String,
    /// True when the server set isError=true OR transport failed.
    pub is_error: bool,
    /// The raw `structuredContent` from the response, JSON-encoded so
    /// downstream policies can re-parse without losing types.
    pub structured: String,
    /// Transport-level error message ; empty on success.
    pub error: String,
}

/// Dispatch one MCP tool call.
///
/// Spawns the named server, does the initialize / initialized / tools/call
/// / close dance, returns the captured response.
pub fn dispatch(
    server: &str,
    tool: &str,
    args: &serde_json::Value,
) -> McpToolResult {
    let mut out = McpToolResult::default();

    let (program, prog_args) = match resolve_server_spawn(server) {
        Some(p) => p,
        None => {
            out.is_error = true;
            out.error = format!("mcp : unknown server '{}' (v1 supports :storehouse only)", server);
            return out;
        }
    };

    let mut session = match McpSession::spawn(&program, &prog_args) {
        Ok(s) => s,
        Err(e) => {
            out.is_error = true;
            out.error = e;
            return out;
        }
    };

    // initialize — the MCP handshake. Send minimum-viable client info.
    let init_id = match session.send_request(
        "initialize",
        serde_json::json!({
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": { "name": "storehouse-mcp-client", "version": "0.1.0" },
        }),
    ) {
        Ok(id) => id,
        Err(e) => {
            out.is_error = true;
            out.error = e;
            return out;
        }
    };

    // Wait for initialize result with a soft timeout (server should
    // respond within seconds). We don't enforce timeout via thread —
    // BufRead::read_line blocks ; spawn-level failures already returned
    // above. If the server hangs, the dispatcher hangs ; v1 trade-off.
    let _init_result = match session.await_response(init_id) {
        Ok(v) => v,
        Err(e) => {
            out.is_error = true;
            out.error = format!("initialize : {}", e);
            return out;
        }
    };

    if let Err(e) = session.send_notification("notifications/initialized", serde_json::json!({})) {
        out.is_error = true;
        out.error = format!("notifications/initialized : {}", e);
        return out;
    }

    let call_id = match session.send_request(
        "tools/call",
        serde_json::json!({
            "name": tool,
            "arguments": args,
        }),
    ) {
        Ok(id) => id,
        Err(e) => {
            out.is_error = true;
            out.error = format!("tools/call : {}", e);
            return out;
        }
    };

    let call_result = match session.await_response(call_id) {
        Ok(v) => v,
        Err(e) => {
            out.is_error = true;
            out.error = format!("tools/call : {}", e);
            return out;
        }
    };

    // Extract content[].text — most tools return one text block, but
    // we concatenate to be safe.
    if let Some(content_array) = call_result.get("content").and_then(|v| v.as_array()) {
        let mut joined = String::new();
        for item in content_array {
            if item.get("type").and_then(|v| v.as_str()) == Some("text") {
                if let Some(t) = item.get("text").and_then(|v| v.as_str()) {
                    if !joined.is_empty() { joined.push('\n'); }
                    joined.push_str(t);
                }
            }
        }
        out.text = joined;
    }
    if call_result.get("isError").and_then(|v| v.as_bool()) == Some(true) {
        out.is_error = true;
    }
    if let Some(sc) = call_result.get("structuredContent") {
        out.structured = serde_json::to_string(sc).unwrap_or_default();
    }

    // Drop the session — Drop impl waits the child.
    let _ = session;
    let _ = Duration::from_millis(0); // marker : we intentionally don't enforce wait timeout
    out
}

// ─────────────────────────────────────────────────────────────────────
//  Kernel hook : the registry entry point
// ─────────────────────────────────────────────────────────────────────

/// Public alias of `substitute` so the runtime's `resolve_mcp_adapters`
/// arm (i594) can run the same placeholder pass before calling
/// `dispatch`. Kept distinct from the private internal symbol so the
/// kernel-hook path (`dispatch_via_registry`) stays its own surface.
pub fn substitute_value(value: serde_json::Value, attrs: &HashMap<String, String>) -> serde_json::Value {
    substitute(value, attrs)
}

/// Substitute `{attr_name}` placeholders in a JSON value's string
/// fields using `command_attrs`. Walks the JSON tree recursively ;
/// only string values are substituted. Unknown placeholders pass
/// through unchanged (the MCP tool will surface the error).
fn substitute(value: serde_json::Value, attrs: &HashMap<String, String>) -> serde_json::Value {
    match value {
        serde_json::Value::String(s) => {
            let mut out = s;
            for (k, v) in attrs {
                let placeholder = format!("{{{}}}", k);
                if out.contains(&placeholder) {
                    out = out.replace(&placeholder, v);
                }
            }
            serde_json::Value::String(out)
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.into_iter().map(|v| substitute(v, attrs)).collect())
        }
        serde_json::Value::Object(obj) => {
            let mut out = serde_json::Map::new();
            for (k, v) in obj {
                out.insert(k, substitute(v, attrs));
            }
            serde_json::Value::Object(out)
        }
        v => v,
    }
}

/// Adapt the MCP dispatcher to the `KernelHook` signature the framework
/// registry expects. `adapter_fields` carries the adapter's declared
/// fields (`server`, `tool`, `args`, `command`, `result_into`) ;
/// `command_attrs` carries the dispatched command's attributes
/// (used for placeholder substitution in `args`).
pub fn dispatch_via_registry(
    adapter_fields: &HashMap<String, String>,
    command_attrs: &HashMap<String, String>,
) -> KernelResult {
    let server = adapter_fields.get("server").cloned().unwrap_or_default();
    let tool = adapter_fields.get("tool").cloned().unwrap_or_default();

    // :args arrives as a JSON-encoded string ; parse, substitute, repass.
    // If the field is missing or empty, pass an empty object so tools
    // that take no args still work.
    let args_raw = adapter_fields.get("args").cloned().unwrap_or_default();
    let args_value: serde_json::Value = if args_raw.is_empty() {
        serde_json::Value::Object(Default::default())
    } else {
        match serde_json::from_str(&args_raw) {
            Ok(v) => v,
            Err(e) => {
                return KernelResult {
                    kind: "mcp".into(),
                    ok: false,
                    output: String::new(),
                    exit_code: 0,
                    error: Some(format!("mcp : args is not JSON : {}", e)),
                };
            }
        }
    };
    let args_substituted = substitute(args_value, command_attrs);

    let r = dispatch(&server, &tool, &args_substituted);
    KernelResult {
        kind: format!("mcp:{}", tool),
        ok: !r.is_error,
        output: if r.text.is_empty() { r.structured.clone() } else { r.text },
        exit_code: 0,
        error: if r.error.is_empty() { None } else { Some(r.error) },
    }
}
