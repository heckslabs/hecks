//! [antibody-exempt: rust/src/runtime/web_tool_dispatcher.rs —
//!  kernel-floor handler for the `:web_tool` hecksagon adapter
//!  family (i569). Implements two behavior_kinds declared under
//!  hecks_conception/aggregates/framework/behavior_kinds/ :
//!  `perform_web_fetch` (HTTP GET via curl shell-out) and
//!  `perform_web_search` (DuckDuckGo HTML-lite query). Sibling
//!  kernel-floor port to claude_tool_dispatcher.rs and
//!  sms_dispatcher.rs ; both retire when i557's framework-wide
//!  kernel-hook registry replaces hard-coded handler tables. This
//!  module exposes `register_web_tool_hooks` for that registry to
//!  consume ; it deliberately does NOT touch `Runtime::dispatch`.]
//!
//! WebToolDispatcher — kernel hook for the :web_tool adapter family
//!
//! When a Tools.WebFetch / Tools.WebSearch command dispatches, the
//! runtime locates the matching `:web_tool` adapter declared in a
//! loaded hecksagon (the `framework/tools/tools.hecksagon`
//! bindings), reads its `tool` field, and calls one of the two
//! native primitives below.
//!
//! Pattern mirrors claude_tool_dispatcher : take the adapter's
//! declared fields + the dispatched command's attrs, execute,
//! return a structured result the Runtime can chain back via the
//! adapter's `result_into` target.
//!
//! ── Scope ──
//!
//! Two native primitives in v1 :
//!   * web_fetch  — curl shell-out for a plain HTTP GET. URLs are
//!                  validated for safety (no file://, no localhost,
//!                  no RFC1918 ranges) before any network call.
//!                  Captured body capped at 100 KB.
//!   * web_search — DuckDuckGo HTML-lite query (no API key). Pulls
//!                  the response HTML, extracts top-N result blocks,
//!                  formats as plain text. Capped at 100 KB.
//!
//! Network access in unit tests is GATED on the `HECKS_WEB_TOOL_LIVE`
//! env var — when unset, the live-network tests skip ; when set,
//! they hit the real internet. CI defaults to unset.
//!
//! ── Wire-in with i557 ──
//!
//! i557 is building `framework_registry.rs` — a typed registry that
//! walks `framework/adapter_families/` + `framework/behavior_kinds/`
//! at boot and dispatches kernel hooks by behavior name. Once that
//! lands, the runtime calls `register_web_tool_hooks(&mut registry)`
//! to populate the two `perform_web_*` slots. Until then this module
//! is callable but unwired — `Runtime::dispatch` is NOT modified.

use std::collections::HashMap;
use std::process::Command;

/// What a :web_tool dispatch produced. Fields are populated per the
/// tool kind that ran — :web_fetch sets `output` to the response
/// body, :web_search sets `output` to the formatted result list.
/// `exit_code` carries the HTTP status (or provider status) so
/// downstream policies can branch on 2xx / 4xx / 5xx the same way
/// they branch on a shell exit.
#[derive(Debug, Clone, Default)]
pub struct WebToolResult {
    /// The tool that ran ("web_fetch" or "web_search").
    pub tool: String,
    /// True if the call succeeded — 2xx status + parseable response.
    pub ok: bool,
    /// Response body / formatted search results — kind-specific.
    pub output: String,
    /// HTTP status code (or provider status). 0 if not applicable.
    pub exit_code: i32,
    /// Human-readable error message when `ok == false`.
    pub error: Option<String>,
}

/// Dispatch a :web_tool adapter call. `tool` is the adapter's
/// declared `tool:` field (`"web_fetch"` or `"web_search"`). `attrs`
/// carries the dispatched command's attributes — `url` for fetch,
/// `query` for search.
pub fn dispatch(tool: &str, attrs: &HashMap<String, String>) -> WebToolResult {
    match tool {
        "web_fetch"  => run_web_fetch(attrs),
        "web_search" => run_web_search(attrs),
        other        => WebToolResult {
            tool: other.to_string(),
            ok: false,
            error: Some(format!("unknown web tool kind: {}", other)),
            ..Default::default()
        },
    }
}

/// Maximum bytes of captured output any web tool returns — caps
/// downstream state for large pages / wide search-result pages.
const OUTPUT_LIMIT_BYTES: usize = 102_400; // 100 KB

fn truncate(s: String) -> String {
    if s.len() <= OUTPUT_LIMIT_BYTES {
        s
    } else {
        let mut t = s.into_bytes();
        t.truncate(OUTPUT_LIMIT_BYTES);
        let mut out = String::from_utf8_lossy(&t).into_owned();
        out.push_str("\n\n... [truncated]");
        out
    }
}

// ── URL safety ──
//
// Reject URLs that point at the local network or local filesystem
// before any network call fires. The list mirrors RFC1918 + loopback
// + link-local. A consumer could still craft a URL pointing at an
// internal-DNS hostname that resolves to a private IP — that's a
// limitation of pre-resolution validation, called out in i569.

/// Returns Some(error_message) if the URL is unsafe, None if it's OK.
fn validate_url(url: &str) -> Option<String> {
    let lower = url.to_lowercase();

    // Reject non-http(s) schemes outright.
    if lower.starts_with("file://") {
        return Some("rejected scheme: file://".into());
    }
    if !(lower.starts_with("http://") || lower.starts_with("https://")) {
        return Some(format!("rejected scheme (only http/https allowed): {}", url));
    }

    // Extract host substring : after scheme, before next '/' or ':'
    let after_scheme = if let Some(rest) = lower.strip_prefix("http://") {
        rest
    } else if let Some(rest) = lower.strip_prefix("https://") {
        rest
    } else {
        return Some("scheme parse failure".into());
    };
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

    // Numeric IPv4 check — split into octets, match against the
    // forbidden ranges. Any non-numeric host (DNS names) skips this.
    let parts: Vec<&str> = host.split('.').collect();
    if parts.len() == 4 && parts.iter().all(|p| p.parse::<u8>().is_ok()) {
        let octets: Vec<u8> = parts.iter().map(|p| p.parse::<u8>().unwrap()).collect();
        if octets[0] == 127 {
            return Some(format!("rejected loopback IP: {}", host));
        }
        if octets[0] == 10 {
            return Some(format!("rejected RFC1918 IP: {}", host));
        }
        if octets[0] == 192 && octets[1] == 168 {
            return Some(format!("rejected RFC1918 IP: {}", host));
        }
        if octets[0] == 172 && (16..=31).contains(&octets[1]) {
            return Some(format!("rejected RFC1918 IP: {}", host));
        }
        if octets[0] == 169 && octets[1] == 254 {
            return Some(format!("rejected link-local IP: {}", host));
        }
        if octets[0] == 0 {
            return Some(format!("rejected reserved IP: {}", host));
        }
    }

    None
}

// ── :web_fetch — curl GET <url>, capture body + HTTP status ──

const USER_AGENT: &str = "hecks-web-tool/0.1 (+https://github.com/embryonaut/hecks)";

fn run_web_fetch(attrs: &HashMap<String, String>) -> WebToolResult {
    let url = match attrs.get("url") {
        Some(u) => u.clone(),
        None => return err("web_fetch", "missing required attr: url", 400),
    };

    if let Some(reason) = validate_url(&url) {
        return err("web_fetch", &format!("url validation failed: {}", reason), 400);
    }

    // curl flags :
    //   -s    silent (no progress meter)
    //   -L    follow redirects
    //   -A    User-Agent
    //   -w    write-out HTTP status code on its own line at the end
    //   --max-time 30  cap total transfer at 30 seconds
    //   --max-filesize 1048576  cap downloaded body at 1 MB
    let output = Command::new("curl")
        .args([
            "-sL",
            "-A", USER_AGENT,
            "--max-time", "30",
            "--max-filesize", "1048576",
            "-w", "\n__HTTP_STATUS__:%{http_code}",
            &url,
        ])
        .output();

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
            // The body ends with our `\n__HTTP_STATUS__:NNN` sentinel.
            // Split it back into (body, status).
            let (body, status_code) = match stdout.rfind("\n__HTTP_STATUS__:") {
                Some(idx) => {
                    let status_str = &stdout[idx + "\n__HTTP_STATUS__:".len()..];
                    let status: i32 = status_str.trim().parse().unwrap_or(0);
                    (stdout[..idx].to_string(), status)
                }
                None => (stdout, 0),
            };

            if !out.status.success() && status_code == 0 {
                let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
                return err(
                    "web_fetch",
                    &format!("curl failed: {}", stderr.trim()),
                    out.status.code().unwrap_or(-1),
                );
            }

            let ok = (200..400).contains(&status_code);
            WebToolResult {
                tool: "web_fetch".into(),
                ok,
                output: truncate(body),
                exit_code: status_code,
                error: if ok {
                    None
                } else {
                    Some(format!("HTTP {}", status_code))
                },
            }
        }
        Err(e) => err("web_fetch", &format!("spawn curl failed: {}", e), -1),
    }
}

// ── :web_search — DuckDuckGo HTML-lite query, parse top-N results ──

fn run_web_search(attrs: &HashMap<String, String>) -> WebToolResult {
    let query = match attrs.get("query") {
        Some(q) => q.clone(),
        None => return err("web_search", "missing required attr: query", 400),
    };
    if query.trim().is_empty() {
        return err("web_search", "query is empty", 400);
    }

    let encoded = url_encode(&query);
    let url = format!("https://html.duckduckgo.com/html/?q={}", encoded);

    let output = Command::new("curl")
        .args([
            "-sL",
            "-A", USER_AGENT,
            "--max-time", "30",
            "--max-filesize", "2097152",
            "-w", "\n__HTTP_STATUS__:%{http_code}",
            &url,
        ])
        .output();

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
            let (body, status_code) = match stdout.rfind("\n__HTTP_STATUS__:") {
                Some(idx) => {
                    let status_str = &stdout[idx + "\n__HTTP_STATUS__:".len()..];
                    let status: i32 = status_str.trim().parse().unwrap_or(0);
                    (stdout[..idx].to_string(), status)
                }
                None => (stdout, 0),
            };

            if !out.status.success() && status_code == 0 {
                let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
                return err(
                    "web_search",
                    &format!("curl failed: {}", stderr.trim()),
                    out.status.code().unwrap_or(-1),
                );
            }
            if !(200..400).contains(&status_code) {
                return WebToolResult {
                    tool: "web_search".into(),
                    ok: false,
                    output: truncate(body),
                    exit_code: status_code,
                    error: Some(format!("HTTP {}", status_code)),
                };
            }

            let results = parse_duckduckgo_html(&body, 10);
            if results.is_empty() {
                return WebToolResult {
                    tool: "web_search".into(),
                    ok: false,
                    output: String::new(),
                    exit_code: status_code,
                    error: Some(
                        "no results parsed (provider response shape may have changed)".into(),
                    ),
                };
            }
            let formatted = format_search_results(&results);
            WebToolResult {
                tool: "web_search".into(),
                ok: true,
                output: truncate(formatted),
                exit_code: status_code,
                error: None,
            }
        }
        Err(e) => err("web_search", &format!("spawn curl failed: {}", e), -1),
    }
}

/// A parsed DuckDuckGo result block — (title, url, snippet).
#[derive(Debug, Clone, PartialEq)]
struct SearchResult {
    title: String,
    url: String,
    snippet: String,
}

/// Walk DuckDuckGo's HTML-lite response, extract up to `limit`
/// result blocks. The shape is small enough that a regex-style
/// substring walk is robust ; introducing a real HTML parser is
/// follow-on work if/when the shape complexity grows.
fn parse_duckduckgo_html(html: &str, limit: usize) -> Vec<SearchResult> {
    let mut results: Vec<SearchResult> = Vec::new();
    let mut cursor = 0;
    while results.len() < limit {
        // Each result block opens with `class="result__a"` on an
        // anchor element. We find the anchor, then walk its href
        // attribute, then its text content for the title, then look
        // for the next snippet anchor / div with class result__snippet.
        let block_start = match html[cursor..].find("class=\"result__a\"") {
            Some(i) => cursor + i,
            None => break,
        };
        // Locate the anchor's opening '<a' before the class attr.
        let anchor_open = match html[..block_start].rfind("<a ") {
            Some(i) => i,
            None => {
                cursor = block_start + 1;
                continue;
            }
        };
        // Extract href="..."
        let anchor_end = match html[anchor_open..].find('>') {
            Some(i) => anchor_open + i,
            None => break,
        };
        let anchor_attrs = &html[anchor_open..anchor_end];
        let url = match extract_attr(anchor_attrs, "href") {
            Some(u) => u,
            None => {
                cursor = anchor_end + 1;
                continue;
            }
        };
        // Title is the text between '>' and '</a>'.
        let title_start = anchor_end + 1;
        let title_end = match html[title_start..].find("</a>") {
            Some(i) => title_start + i,
            None => break,
        };
        let title = strip_tags(&html[title_start..title_end]).trim().to_string();
        if title.is_empty() {
            cursor = title_end + 4;
            continue;
        }
        // Look for a snippet right after — class="result__snippet"
        let snippet = match html[title_end..].find("class=\"result__snippet\"") {
            Some(snip_idx) => {
                let abs = title_end + snip_idx;
                if let Some(snip_open_end) = html[abs..].find('>') {
                    let snip_text_start = abs + snip_open_end + 1;
                    if let Some(snip_text_end) = html[snip_text_start..].find("</a>") {
                        strip_tags(&html[snip_text_start..snip_text_start + snip_text_end])
                            .trim()
                            .to_string()
                    } else {
                        String::new()
                    }
                } else {
                    String::new()
                }
            }
            None => String::new(),
        };

        results.push(SearchResult {
            title,
            url: clean_ddg_url(&url),
            snippet,
        });
        cursor = title_end + 4;
    }
    results
}

fn format_search_results(results: &[SearchResult]) -> String {
    let mut s = String::new();
    for (i, r) in results.iter().enumerate() {
        s.push_str(&format!("{}. {}\n", i + 1, r.title));
        s.push_str(&format!("   {}\n", r.url));
        if !r.snippet.is_empty() {
            s.push_str(&format!("   {}\n", r.snippet));
        }
        s.push('\n');
    }
    s
}

/// Pull a specific attribute value out of `<a href="..." class="...">`-shaped text.
fn extract_attr(attrs: &str, name: &str) -> Option<String> {
    let needle = format!("{}=\"", name);
    let idx = attrs.find(&needle)?;
    let start = idx + needle.len();
    let end_offset = attrs[start..].find('"')?;
    Some(attrs[start..start + end_offset].to_string())
}

/// Strip HTML tags out of a text fragment ; replaces with spaces.
fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for ch in s.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(ch),
            _ => {}
        }
    }
    out
}

/// DuckDuckGo wraps result URLs in a redirector — e.g.
///   //duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage
/// Pull the real URL out of the `uddg=` parameter when present ;
/// otherwise return the URL as-is (just normalizing leading //).
fn clean_ddg_url(url: &str) -> String {
    let candidate = if let Some(idx) = url.find("uddg=") {
        let after = &url[idx + 5..];
        let raw = after.split('&').next().unwrap_or(after);
        percent_decode(raw)
    } else {
        url.to_string()
    };
    if let Some(rest) = candidate.strip_prefix("//") {
        format!("https://{}", rest)
    } else {
        candidate
    }
}

/// Minimal percent-decoder — enough for DDG's redirector params.
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (
                hex_val(bytes[i + 1]),
                hex_val(bytes[i + 2]),
            ) {
                out.push((h << 4) | l);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Minimal URL-encode — covers space + common unsafe chars for a
/// query string. Sufficient for DuckDuckGo's `q=` parameter.
fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z'
            | b'a'..=b'z'
            | b'0'..=b'9'
            | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

// ── helpers ──

fn err(tool: &str, msg: &str, exit_code: i32) -> WebToolResult {
    WebToolResult {
        tool: tool.to_string(),
        ok: false,
        output: String::new(),
        exit_code,
        error: Some(msg.to_string()),
    }
}

// ── i557 hook registration ──
//
// i557 builds a typed kernel-hook registry (`FrameworkRegistry`) that
// walks `framework/adapter_families/` + `framework/behavior_kinds/`
// at boot. Adapter families like `:web_tool` register their kernel
// hooks into the registry by behavior name ; when a dispatch fires a
// behavior, the registry looks up the hook and runs it.
//
// This function is the registration point. It's deliberately
// loose-typed (takes a generic insert closure) because i557 is still
// in flight and the precise `FrameworkRegistry::register_hook`
// signature isn't merged to main yet. When i557 lands, the call
// site there will invoke this function with the registry's actual
// insert method ; the registry then dispatches `perform_web_fetch`
// / `perform_web_search` through the closures we register here.
//
// The two hooks share a single underlying primitive : `dispatch`
// (above), branched on `tool`. The registry passes the adapter's
// `tool` field as part of `attrs` ; we read it back and re-enter
// `dispatch`. That keeps this function trivial and lets the
// registry-side wiring stay symmetrical across families.

/// A simplified hook signature : takes the dispatched command's
/// attributes (already merged with adapter fields by the registry)
/// and returns the structured `WebToolResult`. The registry-side
/// wrapper adapts this to whatever closure shape the registry
/// expects (string→string, structured→structured, etc.).
pub type WebToolHook = fn(&HashMap<String, String>) -> WebToolResult;

/// Look up the kernel-hook closure for a given web_tool behavior
/// name. Returns `None` if the behavior isn't one we handle.
///
/// The registry calls this once per `:web_tool` behavior at boot
/// to populate its `kernel_hooks` map. Decoupled from the registry's
/// exact API so this module stays buildable before i557 merges.
pub fn lookup_hook(behavior_name: &str) -> Option<WebToolHook> {
    match behavior_name {
        "perform_web_fetch"  => Some(perform_web_fetch_hook),
        "perform_web_search" => Some(perform_web_search_hook),
        _ => None,
    }
}

fn perform_web_fetch_hook(attrs: &HashMap<String, String>) -> WebToolResult {
    run_web_fetch(attrs)
}

fn perform_web_search_hook(attrs: &HashMap<String, String>) -> WebToolResult {
    run_web_search(attrs)
}

/// The two behavior names this module owns — exposed so the
/// registry's boot path can iterate them without hardcoding the
/// list at the registry side.
pub const WEB_TOOL_BEHAVIOR_NAMES: &[&str] = &[
    "perform_web_fetch",
    "perform_web_search",
];

#[cfg(test)]
mod tests {
    use super::*;

    fn attrs(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    // ── URL safety ──

    #[test]
    fn forbidden_localhost_url_is_rejected() {
        let r = dispatch("web_fetch", &attrs(&[("url", "http://localhost:8080/x")]));
        assert!(!r.ok, "{:?}", r);
        let e = r.error.expect("error required");
        assert!(e.contains("rejected"), "got: {}", e);
    }

    #[test]
    fn forbidden_loopback_ip_is_rejected() {
        let r = dispatch("web_fetch", &attrs(&[("url", "http://127.0.0.1/")]));
        assert!(!r.ok);
        let e = r.error.unwrap();
        assert!(e.contains("loopback") || e.contains("rejected"), "got: {}", e);
    }

    #[test]
    fn forbidden_rfc1918_ip_is_rejected() {
        for ip in &["10.0.0.1", "192.168.1.1", "172.16.0.1"] {
            let r = dispatch("web_fetch", &attrs(&[("url", &format!("http://{}/x", ip))]));
            assert!(!r.ok, "ip {} should be rejected: {:?}", ip, r);
        }
    }

    #[test]
    fn forbidden_file_scheme_is_rejected() {
        let r = dispatch("web_fetch", &attrs(&[("url", "file:///etc/passwd")]));
        assert!(!r.ok);
        let e = r.error.unwrap();
        assert!(e.contains("file"), "got: {}", e);
    }

    #[test]
    fn unknown_tool_returns_error() {
        let r = dispatch("nonsense", &attrs(&[]));
        assert!(!r.ok);
        assert!(r.error.unwrap().contains("unknown web tool kind"));
    }

    #[test]
    fn web_fetch_missing_url_errors() {
        let r = dispatch("web_fetch", &attrs(&[]));
        assert!(!r.ok);
        assert!(r.error.unwrap().contains("missing required attr: url"));
    }

    #[test]
    fn web_search_missing_query_errors() {
        let r = dispatch("web_search", &attrs(&[]));
        assert!(!r.ok);
        assert!(r.error.unwrap().contains("missing required attr: query"));
    }

    #[test]
    fn web_search_empty_query_errors() {
        let r = dispatch("web_search", &attrs(&[("query", "")]));
        assert!(!r.ok);
    }

    // ── Truncation ──

    #[test]
    fn truncate_caps_long_strings() {
        let huge = "x".repeat(OUTPUT_LIMIT_BYTES + 100);
        let t = truncate(huge);
        assert!(t.len() <= OUTPUT_LIMIT_BYTES + 32, "got len {}", t.len());
        assert!(t.contains("[truncated]"));
    }

    // ── URL helpers ──

    #[test]
    fn url_encode_handles_spaces_and_symbols() {
        assert_eq!(url_encode("hello world"), "hello%20world");
        assert_eq!(url_encode("a&b=c"), "a%26b%3Dc");
        assert_eq!(url_encode("simple-name.tld_v1~"), "simple-name.tld_v1~");
    }

    #[test]
    fn percent_decode_round_trip() {
        assert_eq!(percent_decode("hello%20world"), "hello world");
        assert_eq!(percent_decode("a%26b%3Dc"), "a&b=c");
        assert_eq!(percent_decode("https%3A%2F%2Fexample.com"), "https://example.com");
    }

    #[test]
    fn clean_ddg_url_unwraps_redirector() {
        let raw = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpath&rut=abc";
        assert_eq!(clean_ddg_url(raw), "https://example.com/path");
    }

    #[test]
    fn clean_ddg_url_passes_through_plain_https() {
        assert_eq!(clean_ddg_url("https://example.com/page"),
                   "https://example.com/page");
    }

    // ── HTML parsing ──

    #[test]
    fn parse_duckduckgo_html_extracts_results() {
        let html = r##"<html><body>
            <div class="result">
              <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com">Example Title</a>
              <a class="result__snippet" href="#">First snippet text</a>
            </div>
            <div class="result">
              <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Frust-lang.org">Rust Lang</a>
              <a class="result__snippet" href="#">Second snippet text</a>
            </div>
        </body></html>"##;
        let results = parse_duckduckgo_html(html, 10);
        assert_eq!(results.len(), 2, "got: {:?}", results);
        assert_eq!(results[0].title, "Example Title");
        assert_eq!(results[0].url, "https://example.com");
        assert_eq!(results[0].snippet, "First snippet text");
        assert_eq!(results[1].title, "Rust Lang");
        assert_eq!(results[1].url, "https://rust-lang.org");
    }

    #[test]
    fn parse_duckduckgo_html_empty_when_no_results() {
        let html = "<html><body>nothing here</body></html>";
        let results = parse_duckduckgo_html(html, 10);
        assert!(results.is_empty());
    }

    // ── Lookup / registration shape ──

    #[test]
    fn lookup_hook_resolves_both_behaviors() {
        assert!(lookup_hook("perform_web_fetch").is_some());
        assert!(lookup_hook("perform_web_search").is_some());
    }

    #[test]
    fn lookup_hook_returns_none_for_unknown() {
        assert!(lookup_hook("perform_text_to_speech").is_none());
        assert!(lookup_hook("").is_none());
    }

    #[test]
    fn behavior_names_lists_two_entries() {
        assert_eq!(WEB_TOOL_BEHAVIOR_NAMES.len(), 2);
        assert!(WEB_TOOL_BEHAVIOR_NAMES.contains(&"perform_web_fetch"));
        assert!(WEB_TOOL_BEHAVIOR_NAMES.contains(&"perform_web_search"));
    }

    // ── Live-network tests ──
    //
    // These hit the real internet ; gated on HECKS_WEB_TOOL_LIVE=1.
    // CI defaults to unset so the suite stays hermetic.

    fn live_network_enabled() -> bool {
        std::env::var("HECKS_WEB_TOOL_LIVE").ok().as_deref() == Some("1")
    }

    #[test]
    fn live_web_fetch_against_example_com() {
        if !live_network_enabled() { return; }
        let r = dispatch("web_fetch", &attrs(&[("url", "https://example.com/")]));
        assert!(r.ok, "{:?}", r);
        assert!(r.output.contains("Example Domain"), "body: {}", r.output);
        assert_eq!(r.exit_code, 200);
    }

    #[test]
    fn live_web_search_returns_results() {
        if !live_network_enabled() { return; }
        let r = dispatch("web_search", &attrs(&[("query", "rust lang")]));
        // Don't strictly require ok — DDG sometimes throttles, but
        // we should at least get a structured outcome.
        if r.ok {
            assert!(!r.output.is_empty());
        } else {
            assert!(r.error.is_some());
        }
    }
}
