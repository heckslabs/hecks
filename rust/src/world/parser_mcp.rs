//! World MCP-block parser (i610) — the `mcp do; server :name do; ... end end`
//! family, split out of world_parser.rs so each file stays under the
//! 200-line code budget. Declares the MCP servers a `.world` file wires:
//! each server's name (the symbol an `adapter :mcp, server: :name` binding
//! references) and the env var its auth token is read from at dispatch.
//!
//! ```text
//! Hecks.world "Tools" do
//!   mcp do
//!     server :gmail do
//!       token_env "MIETTE_GMAIL_ACCESS_TOKEN"
//!     end
//!   end
//! end
//! ```

use crate::hecksagon_helpers::between_quotes;
use crate::world::ir::McpServer;
use crate::world::parser::{absorb_inline_block_body, ends_with_do, parse_kv_line};

/// Parse `mcp do; server :name do; token_env "..." end ... end`. Returns the
/// declared servers + the number of source lines consumed. Each `server`
/// header inside the mcp block opens a nested block whose only recognized
/// key today is `token_env`.
pub fn parse_mcp_block(lines: &[&str]) -> (Vec<McpServer>, usize) {
    let mut servers: Vec<McpServer> = vec![];
    let first = lines[0].trim();

    let mut i = 1;
    let mut depth = if ends_with_do(first) { 1 } else { 0 };
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" { depth -= 1; i += 1; continue; }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        if t.starts_with("server ") || t.starts_with("server:") {
            let (server, consumed) = parse_server_block(&lines[i..]);
            if let Some(s) = server { servers.push(s); }
            i += consumed;
            continue;
        }
        if ends_with_do(t) { depth += 1; }
        i += 1;
    }
    (servers, i)
}

/// Parse one `server :name do; token_env "..." end` block. The name is the
/// first quoted string OR the `:symbol` token after `server`; the leading
/// `:` is stripped so the canonical name matches Ruby's `.to_s`.
fn parse_server_block(lines: &[&str]) -> (Option<McpServer>, usize) {
    let first = lines[0].trim();
    let mut server = McpServer { name: server_name(first), token_env: None };

    // Inline: `server :x do; token_env "y" end`
    if first.ends_with("end") && first.contains("do") {
        absorb_inline_block_body(first, &mut |k, v| {
            if k == "token_env" { server.token_env = Some(v); }
        });
        return (if server.name.is_empty() { None } else { Some(server) }, 1);
    }

    let mut i = 1;
    let mut depth = if ends_with_do(first) { 1 } else { 0 };
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" { depth -= 1; i += 1; continue; }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        if ends_with_do(t) { depth += 1; i += 1; continue; }
        if let Some((k, v)) = parse_kv_line(t) {
            if k == "token_env" { server.token_env = Some(v); }
        }
        i += 1;
    }
    (if server.name.is_empty() { None } else { Some(server) }, i)
}

/// Extract the server name from a `server :name do` / `server "name" do`
/// header. Looks ONLY at the text before the `do` keyword so an inline
/// body (`server :x do; token_env "y" end`) can't leak its quoted value
/// into the name. Prefers a quoted string; falls back to the `:symbol`
/// token (leading `:` stripped). Empty string when neither is found.
fn server_name(header: &str) -> String {
    let before_do = match header.find(" do") {
        Some(idx) => &header[..idx],
        None => header,
    };
    let after = before_do.trim_start_matches("server").trim();
    if let Some(q) = between_quotes(after) { return q; }
    let token: String = after
        .chars()
        .take_while(|c| c.is_alphanumeric() || *c == '_' || *c == ':')
        .collect();
    token.trim_start_matches(':').to_string()
}
