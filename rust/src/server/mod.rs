// [antibody-exempt: rust/src/server/mod.rs — storehouse engine HTTP server entry
//  (listener, request parse, module wiring). Kernel Rust transport that serves
//  bluebook runtimes over HTTP ; it cannot be bluebook vocabulary (it IS the
//  runtime's surface). Engine surface, same class as routes.rs.]
//! HTTP Server — JSON API for domain runtimes
//!
//! Zero-dependency HTTP server using std::net. Serves one or many
//! domains as a REST-ish API: dispatch commands, query aggregates.
//!
//! Usage:
//!   storehouse serve pizzas.bluebook 3100
//!   storehouse serve path/to/hecks/ 3100

pub mod routes;
pub mod multi;
pub mod html;
pub mod html_diagram;
pub mod html_domain;
pub mod html_form;
pub mod user_flows;
pub mod web_adapter;
pub mod html_fixtures;
pub mod html_help;
pub mod html_icons;
pub mod html_kpi;
pub mod html_scripts;
pub mod html_shared;
pub mod html_sidebar;
pub mod html_wizard;
pub mod html_narration;
pub mod html_policy_chain;
pub mod html_query;
pub mod html_rules;
pub mod html_usage;
pub mod html_workflow;

pub use routes::route;

use crate::runtime::Runtime;
use std::cell::RefCell;
use std::io::{Write, BufRead, BufReader, Read};
use std::net::TcpListener;

/// Serve a single domain (backward-compatible entry point)
pub fn serve(rt: Runtime, port: u16) {
    let rt = RefCell::new(rt);
    let addr = format!("0.0.0.0:{}", port);
    let listener = TcpListener::bind(&addr).unwrap_or_else(|e| {
        eprintln!("Cannot bind {}: {}", addr, e);
        std::process::exit(1);
    });

    let domain_name = rt.borrow().domain.name.clone();
    eprintln!("Hecks Life — {} on http://localhost:{}", domain_name, port);

    for stream in listener.incoming().flatten() {
        handle_single(stream, &rt);
    }
}

fn handle_single(mut stream: std::net::TcpStream, rt: &RefCell<Runtime>) {
    let req = match read_request(&stream) {
        Some(r) => r,
        None => return,
    };
    // POSTURE DEFAULT (single-file arm) : `storehouse serve <file.bluebook>`
    // does no `.world` walk at all, so its door posture is always Open — a
    // header-less caller stamps as System, exactly today's behavior. A
    // governed single-file deployment would need the minimal extension of
    // parsing a sibling `.world` next to the served bluebook ; until one
    // materialises, governed doors are a `serve <dir>` concern (multi.rs).
    let (status, resp_body) = routes::route(
        &req.method, &req.path, &req.body, req.bearer.as_deref(),
        crate::runtime::acl_readmodel::DoorPosture::Open, rt,
    );
    write_response(&mut stream, status, &resp_body);
}

/// One parsed HTTP request at the serve door. `bearer` carries the
/// `Authorization: Bearer <token>` header value when present — the caller's
/// auth_identity_id, stamped per REQUEST (a resident door serves many
/// callers ; the per-process env cannot identify them). A struct rather than
/// a widened tuple : a fourth positional Option across three call sites
/// invites transposition bugs.
pub struct Request {
    pub method: String,
    pub path: String,
    pub body: String,
    pub bearer: Option<String>,
}

/// Read an HTTP request — request line, the Content-Length and
/// Authorization headers, and the body.
pub fn read_request(stream: &std::net::TcpStream) -> Option<Request> {
    let mut reader = BufReader::new(stream);
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).is_err() { return None; }

    let parts: Vec<&str> = request_line.trim().split_whitespace().collect();
    if parts.len() < 2 { return None; }
    let method = parts[0].to_string();
    let path = parts[1].to_string();

    let mut content_length = 0usize;
    let mut bearer: Option<String> = None;
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header).is_err() { return None; }
        if header.trim().is_empty() { break; }
        let lower = header.to_lowercase();
        if lower.starts_with("content-length:") {
            content_length = header[15..].trim().parse().unwrap_or(0);
        }
        if lower.starts_with("authorization:") {
            // `Authorization: Bearer <token>` — scheme is case-insensitive.
            let value = header[14..].trim();
            if value.len() > 7 && value[..7].eq_ignore_ascii_case("bearer ") {
                let token = value[7..].trim();
                if !token.is_empty() {
                    bearer = Some(token.to_string());
                }
            }
        }
    }

    let body = if content_length > 0 {
        let mut buf = vec![0u8; content_length];
        reader.read_exact(&mut buf).ok();
        String::from_utf8(buf).unwrap_or_default()
    } else {
        String::new()
    };

    Some(Request { method, path, body, bearer })
}

/// Write an HTTP response with CORS headers
pub fn write_response(stream: &mut std::net::TcpStream, status: &str, body: &str) {
    let content_type = if body.starts_with("<!") || body.starts_with("<h") {
        "text/html"
    } else {
        "application/json"
    };
    let resp = format!(
        "HTTP/1.1 {}\r\nContent-Type: {}\r\n\
         Access-Control-Allow-Origin: *\r\n\
         Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n\
         Access-Control-Allow-Headers: Content-Type, Authorization\r\n\
         Content-Length: {}\r\n\r\n{}",
        status, content_type, body.len(), body
    );
    let _ = stream.write_all(resp.as_bytes());
}
