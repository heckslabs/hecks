//! :mcp world-server resolution (i610) — carved out of runtime/mod.rs into
//! the `adapter_resolution` GROW concern. The `*.world` files declare which
//! MCP servers a domain wires (`mcp do; server :name do; token_env "…" end`)
//! ; this arm resolves an `adapter :mcp, server: :name` binding's server
//! against those declarations, reads its `token_env`, and logs the resolve.
//!
//! [antibody-exempt: rust/src/adapter_resolution/mcp.rs — kernel-floor
//!  adapter arm. World-server resolution is the kernel side of the i610
//!  `mcp do … end` world-grammar block ; it reads the declared server +
//!  token-env at dispatch. No bluebook can describe its own MCP transport
//!  resolution — this is the kernel arm the .world grammar declares.]

use crate::runtime::Runtime;

/// i610 — resolve a `:mcp` binding's `server` against the project's
/// `*.world`-declared servers (attached at boot into `Runtime::world_servers`).
/// A world-declared server carries a `token_env`; the auth token is read from
/// that env var at dispatch. Returns `true` when the server was world-resolved
/// (logged + recorded, the call left to the harness transport — the i610
/// honest gap), so the caller `continue`s past the spawn/skip arms. Returns
/// `false` when no world entry names the server, letting the dispatcher fall
/// through to its spawnable-server guard.
pub(crate) fn resolve_world_server(rt: &Runtime, server: &str) -> bool {
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
    // i610 honest gap : harness-injected Gmail tools are not a
    // locally-spawnable stdio server, so the live HTTP transport
    // is owned by the Claude harness, not this dispatcher. The
    // wiring (server resolved from world + token from env) is in
    // place ; the call is recorded, not invoked.
    eprintln!(
        "[mcp:skip] server={} transport=harness_injected — recorded, not invoked (i610 transport gap)",
        ws.name
    );
    true
}
