use crate::hecksagon_helpers::between_quotes;
use crate::world::ir::McpServer;
use crate::world::parser::{absorb_inline_block_body, ends_with_do, parse_kv_line};

pub fn parse_mcp_block(lines: &[&str]) -> (Vec<McpServer>, usize) {
    let mut servers: Vec<McpServer> = vec![];
    let first = lines[0].trim();

    let mut i = 1;
    let mut depth = if ends_with_do(first) { 1 } else { 0 };
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" {
            depth -= 1;
            i += 1;
            continue;
        }
        if t.is_empty() || t.starts_with('#') {
            i += 1;
            continue;
        }
        if t.starts_with("server ") || t.starts_with("server:") {
            let (server, consumed) = parse_server_block(&lines[i..]);
            if let Some(s) = server {
                servers.push(s);
            }
            i += consumed;
            continue;
        }
        if ends_with_do(t) {
            depth += 1;
        }
        i += 1;
    }
    (servers, i)
}

fn parse_server_block(lines: &[&str]) -> (Option<McpServer>, usize) {
    let first = lines[0].trim();
    let mut server = McpServer {
        name: server_name(first),
        token_env: None,
    };

    if first.ends_with("end") && first.contains("do") {
        absorb_inline_block_body(first, &mut |k, v| {
            if k == "token_env" {
                server.token_env = Some(v);
            }
        });
        return (
            if server.name.is_empty() {
                None
            } else {
                Some(server)
            },
            1,
        );
    }

    let mut i = 1;
    let mut depth = if ends_with_do(first) { 1 } else { 0 };
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" {
            depth -= 1;
            i += 1;
            continue;
        }
        if t.is_empty() || t.starts_with('#') {
            i += 1;
            continue;
        }
        if ends_with_do(t) {
            depth += 1;
            i += 1;
            continue;
        }
        if let Some((k, v)) = parse_kv_line(t) {
            if k == "token_env" {
                server.token_env = Some(v);
            }
        }
        i += 1;
    }
    (
        if server.name.is_empty() {
            None
        } else {
            Some(server)
        },
        i,
    )
}

fn server_name(header: &str) -> String {
    let before_do = match header.find(" do") {
        Some(idx) => &header[..idx],
        None => header,
    };
    let after = before_do.trim_start_matches("server").trim();
    if let Some(q) = between_quotes(after) {
        return q;
    }
    let token: String = after
        .chars()
        .take_while(|c| c.is_alphanumeric() || *c == '_' || *c == ':')
        .collect();
    token.trim_start_matches(':').to_string()
}
