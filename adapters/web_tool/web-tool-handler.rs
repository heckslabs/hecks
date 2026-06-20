//! web-tool-handler (Rust) — a standalone, COMPILED out-of-process `:web_tool`
//! ADAPTER program. The verdict-capturing sibling of the llm-handler : it emits a
//! VERDICT (`output`) the primary-adapter wait threads into the success command.
//! The drainer (NOT this program) dispatches the verdict + marks the delivery
//! delivered.
//!
//! TWO MODES, deterministic-first :
//!   * If WEB_TOOL_FIXTURES is set, look the request up in a TSV fixtures file
//!     (`<tool>:<arg><TAB>output`). This is the TestWeb path — NO real network,
//!     byte-deterministic, used by the keystone proof. A miss yields the lenient
//!     placeholder `[test-web:unknown <tool>=<arg>]`.
//!   * Otherwise it performs the LIVE web call via `curl`, mirroring the
//!     in-process web_tool_dispatcher.rs logic (HTTP GET for web_fetch with the
//!     same URL-safety guard ; DuckDuckGo html-lite for web_search).
//!
//! ADAPTER-HOST CONTRACT (mirrors the run_host exec protocol) :
//!   * STDIN : the trigger event payload as JSON (carries `tool` + `url`/`query`).
//!   * ENV   : the adapter config the wait folds in from .world under the
//!             canonical <FAMILY>_<FIELD> names (WEB_TOOL_TOOL, WEB_TOOL_USER_AGENT,
//!             WEB_TOOL_FIXTURES). The `tool` payload field wins over WEB_TOOL_TOOL.
//!   * STDOUT: `output=<body>` (the family's `produces` contract). Newlines in the
//!             body are escaped to keep the verdict on a single k=v line.
//!   * EXIT  : 0 = success branch (verdict = success_command), non-zero = failure
//!             branch (verdict = failure_command).
//!
//! Build (standalone, zero deps) :
//!   rustc -O adapters/web_tool/web-tool-handler.rs -o adapters/web_tool/web-tool-handler

use std::io::Read;
use std::process::Command;

fn env_opt(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

/// Extract a JSON string value for `key` from `src`, decoding standard escapes.
/// UTF-8 safe. Minimal by design — the payload is a flat object. (Copied from
/// llm-handler.rs : standalone handlers carry their own tiny JSON reader so they
/// have zero crate deps.)
fn json_string_field(src: &str, key: &str) -> Option<String> {
    let pat = format!("\"{}\"", key);
    let start = src.find(&pat)? + pat.len();
    let rest = &src[start..];
    let colon = rest.find(':')?;
    let after = &rest[colon + 1..];
    let q = after.find('"')?;
    let mut out = String::new();
    let mut chars = after[q + 1..].chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some('/') => out.push('/'),
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some('r') => out.push('\r'),
                Some('b') => out.push('\u{08}'),
                Some('f') => out.push('\u{0C}'),
                Some('u') => {
                    let hex: String = chars.by_ref().take(4).collect();
                    if let Ok(n) = u32::from_str_radix(&hex, 16) {
                        if let Some(ch) = char::from_u32(n) {
                            out.push(ch);
                        }
                    }
                }
                Some(other) => out.push(other),
                None => break,
            },
            '"' => return Some(out),
            _ => out.push(c),
        }
    }
    None
}

/// Load a flat-TSV fixtures file : `key<TAB>output` per line. The key is
/// `<tool>:<arg>` (e.g. `web_fetch:https://example.com`). Mirrors the
/// llm-handler's loader shape.
fn load_fixtures(path: &str) -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    if let Ok(contents) = std::fs::read_to_string(path) {
        for line in contents.lines() {
            if let Some((k, body)) = line.split_once('\t') {
                let k = k.trim();
                if !k.is_empty() {
                    out.insert(k.to_string(), body.to_string());
                }
            }
        }
    }
    out
}

/// Escape a body to a single line so it rides one `output=` k=v verdict line
/// (the host's parse_pairs is line-oriented).
fn one_line(s: &str) -> String {
    s.replace('\\', "\\\\").replace('\n', "\\n").replace('\r', "")
}

// ── URL safety ── mirrors web_tool_dispatcher::validate_url. Returns Some(reason)
// if the URL is unsafe, None if OK.
fn validate_url(url: &str) -> Option<String> {
    let lower = url.to_lowercase();
    if lower.starts_with("file://") {
        return Some("rejected scheme: file://".into());
    }
    if !(lower.starts_with("http://") || lower.starts_with("https://")) {
        return Some(format!("rejected scheme (only http/https allowed): {}", url));
    }
    let after_scheme = lower
        .strip_prefix("http://")
        .or_else(|| lower.strip_prefix("https://"))
        .unwrap_or("");
    let host = after_scheme
        .split(|c: char| c == '/' || c == ':' || c == '?' || c == '#')
        .next()
        .unwrap_or("");
    if host.is_empty() {
        return Some("missing host".into());
    }
    if host == "localhost" || host == "::1" {
        return Some(format!("rejected host: {}", host));
    }
    let parts: Vec<&str> = host.split('.').collect();
    if parts.len() == 4 && parts.iter().all(|p| p.parse::<u8>().is_ok()) {
        let o: Vec<u8> = parts.iter().map(|p| p.parse::<u8>().unwrap()).collect();
        if o[0] == 127 || o[0] == 10 || o[0] == 0
            || (o[0] == 192 && o[1] == 168)
            || (o[0] == 172 && (16..=31).contains(&o[1]))
            || (o[0] == 169 && o[1] == 254)
        {
            return Some(format!("rejected private/reserved IP: {}", host));
        }
    }
    None
}

fn url_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

/// LIVE web_fetch : curl GET <url>. Returns (ok, body).
fn live_fetch(url: &str, user_agent: &str) -> (bool, String) {
    if let Some(reason) = validate_url(url) {
        return (false, format!("url validation failed: {}", reason));
    }
    let out = Command::new("curl")
        .args([
            "-sL",
            "-A", user_agent,
            "--max-time", "30",
            "--max-filesize", "1048576",
            "-w", "\n__HTTP_STATUS__:%{http_code}",
            url,
        ])
        .output();
    match out {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout).into_owned();
            let (body, status) = match stdout.rfind("\n__HTTP_STATUS__:") {
                Some(idx) => {
                    let s: i32 = stdout[idx + "\n__HTTP_STATUS__:".len()..]
                        .trim()
                        .parse()
                        .unwrap_or(0);
                    (stdout[..idx].to_string(), s)
                }
                None => (stdout, 0),
            };
            let ok = (200..400).contains(&status);
            (ok, body)
        }
        Err(e) => (false, format!("spawn curl failed: {}", e)),
    }
}

/// LIVE web_search : DuckDuckGo html-lite. Returns (ok, body).
fn live_search(query: &str, user_agent: &str) -> (bool, String) {
    if query.trim().is_empty() {
        return (false, "query is empty".into());
    }
    let url = format!("https://html.duckduckgo.com/html/?q={}", url_encode(query));
    let out = Command::new("curl")
        .args(["-sL", "-A", user_agent, "--max-time", "30", &url])
        .output();
    match out {
        Ok(o) => {
            let ok = o.status.success();
            (ok, String::from_utf8_lossy(&o.stdout).into_owned())
        }
        Err(e) => (false, format!("spawn curl failed: {}", e)),
    }
}

const USER_AGENT: &str = "hecks-web-tool/0.1 (+https://github.com/embryonaut/hecks)";

fn main() {
    let mut raw = String::new();
    let _ = std::io::stdin().read_to_string(&mut raw);

    // `tool` : payload field wins over the WEB_TOOL_TOOL env default.
    let tool = json_string_field(&raw, "tool")
        .or_else(|| env_opt("WEB_TOOL_TOOL"))
        .unwrap_or_else(|| "web_fetch".to_string());
    let arg = match tool.as_str() {
        "web_search" => json_string_field(&raw, "query").unwrap_or_default(),
        _ => json_string_field(&raw, "url").unwrap_or_default(),
    };
    let user_agent = env_opt("WEB_TOOL_USER_AGENT").unwrap_or_else(|| USER_AGENT.to_string());

    // DETERMINISTIC path : fixtures keyed by `<tool>:<arg>`. NO network.
    if let Some(fixtures_path) = env_opt("WEB_TOOL_FIXTURES") {
        let fixtures = load_fixtures(&fixtures_path);
        let key = format!("{}:{}", tool, arg);
        let body = match fixtures.get(&key) {
            Some(text) => text.clone(),
            None => format!("[test-web:unknown {}={}]", tool, arg),
        };
        println!("output={}", one_line(&body));
        std::process::exit(0);
    }

    // LIVE path : real web call (mirrors web_tool_dispatcher.rs).
    let (ok, body) = match tool.as_str() {
        "web_search" => live_search(&arg, &user_agent),
        "web_fetch" => live_fetch(&arg, &user_agent),
        other => (false, format!("unknown web tool kind: {}", other)),
    };
    println!("output={}", one_line(&body));
    std::process::exit(if ok { 0 } else { 1 });
}
