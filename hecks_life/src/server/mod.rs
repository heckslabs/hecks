//! HTTP Server — JSON API for domain runtimes
//!
//! Zero-dependency HTTP server using std::net. Serves one or many
//! domains as a REST-ish API: dispatch commands, query aggregates.
//!
//! Usage:
//!   hecks-life serve pizzas.bluebook 3100
//!   hecks-life serve path/to/hecks/ 3100

pub mod routes;
pub mod multi;
pub mod html;
pub mod html_domain;
pub mod html_fixtures;
pub mod html_help;
pub mod html_icons;
pub mod html_kpi;
pub mod html_scripts;
pub mod html_shared;
pub mod html_sidebar;
pub mod html_wizard;
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
    let (method, path, body) = match read_request(&stream) {
        Some(r) => r,
        None => return,
    };
    let (status, resp_body) = routes::route(&method, &path, &body, rt);
    write_response(&mut stream, status, &resp_body);
}

/// Read an HTTP request, return (method, path, body)
pub fn read_request(stream: &std::net::TcpStream) -> Option<(String, String, String)> {
    let mut reader = BufReader::new(stream);
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).is_err() { return None; }

    let parts: Vec<&str> = request_line.trim().split_whitespace().collect();
    if parts.len() < 2 { return None; }
    let method = parts[0].to_string();
    let path = parts[1].to_string();

    let mut content_length = 0usize;
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header).is_err() { return None; }
        if header.trim().is_empty() { break; }
        if header.to_lowercase().starts_with("content-length:") {
            content_length = header[15..].trim().parse().unwrap_or(0);
        }
    }

    let body = if content_length > 0 {
        let mut buf = vec![0u8; content_length];
        reader.read_exact(&mut buf).ok();
        String::from_utf8(buf).unwrap_or_default()
    } else {
        String::new()
    };

    Some((method, path, body))
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
         Access-Control-Allow-Headers: Content-Type\r\n\
         Content-Length: {}\r\n\r\n{}",
        status, content_type, body.len(), body
    );
    let _ = stream.write_all(resp.as_bytes());
}
