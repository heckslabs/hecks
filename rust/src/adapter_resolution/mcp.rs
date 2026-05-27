//! :mcp world-server resolution (i610) — carved out of runtime/mod.rs into
//! the `adapter_resolution` GROW concern. The `*.world` files declare which
//! MCP servers a domain wires (`mcp do; server :name do; token_env "…" end`)
//! ; this arm resolves an `adapter :mcp, server: :name` binding's server
//! against those declarations, reads its `token_env`, and emits a transport-C
//! event on the storehouse follow stream.
//!
//! [antibody-exempt: rust/src/adapter_resolution/mcp.rs — kernel-floor
//!  adapter arm. World-server resolution is the kernel side of the i610
//!  `mcp do … end` world-grammar block ; it reads the declared server +
//!  token-env at dispatch. No bluebook can describe its own MCP transport
//!  resolution — this is the kernel arm the .world grammar declares.]

use crate::runtime::Runtime;

/// i610 transport C — resolve a `:mcp` binding's `server` against the
/// project's `*.world`-declared servers (attached at boot into
/// `Runtime::world_servers`). When matched, emits an `mcp_dispatch_requested`
/// JSONL event on the `storehouse follow` stream so a harness-side subscriber
/// can pick it up, run the MCP tool, and dispatch `Cascade.RecordResult` back.
/// Returns `true` when the server was world-resolved (caller `continue`s),
/// `false` when no world entry names the server.
///
/// The emitted event shape:
/// ```json
/// {
///   "ts": "<iso8601>",
///   "command": "<Domain::Agg.Cmd that triggered the adapter>",
///   "kind": "mcp_dispatch_requested",
///   "source": "mcp-resolver",
///   "invocation_id": "<id>",
///   "server": "gmail",
///   "tool": "<substituted MCP tool name>",
///   "args": { … },
///   "result_into": "Tools::EmailTool.RecordResult"
/// }
/// ```
pub(crate) fn resolve_world_server(
    rt: &Runtime,
    server: &str,
    tool: &str,
    args: &serde_json::Value,
    result_into: Option<&str>,
    invocation_id: &str,
    trigger_command: &str,
) -> bool {
    let want = server.trim_start_matches(':');
    let Some(ws) = rt.world_servers.iter().find(|s| s.name == want) else {
        return false;
    };
    let token_env = ws.token_env.clone().unwrap_or_default();
    let env_present = !token_env.is_empty()
        && std::env::var(&token_env).map(|v| !v.is_empty()).unwrap_or(false);
    let world_path = rt.world_servers_path.as_deref().unwrap_or("<unknown>");
    eprintln!(
        "[mcp:resolve] server={} world={} token_env={} env_present={}",
        ws.name, world_path, token_env, env_present
    );
    // i610 transport C — emit the mcp_dispatch_requested event on the
    // storehouse follow stream. A harness-side subscriber filters
    // `kind == "mcp_dispatch_requested"`, runs the MCP tool via the
    // harness's own MCP client, then dispatches back via
    // storehouse__dispatch with the command = result_into and attrs
    // matching the Cascade.RecordResult shape (id, tool, output,
    // exit_code, ok).
    let ts = crate::runtime::storehouse_log::now_iso8601();
    let event = serde_json::json!({
        "ts": ts,
        "command": trigger_command,
        "kind": "mcp_dispatch_requested",
        "source": "mcp-resolver",
        "invocation_id": invocation_id,
        "server": ws.name,
        "tool": tool,
        "args": args,
        "result_into": result_into.unwrap_or(""),
    });
    crate::runtime::storehouse_log::emit_file(&event.to_string());
    true
}
