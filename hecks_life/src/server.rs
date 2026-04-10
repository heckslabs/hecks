//! HTTP Server — JSON API for domain runtimes
//!
//! Zero-dependency HTTP server using std::net. Serves a domain
//! as a REST-ish API: dispatch commands, query aggregates, read events.
//!
//! Usage:
//!   hecks-life serve pizzas.bluebook --seed seeds.txt 3100
//!
//! Routes:
//!   POST /dispatch          { "command": "CreatePizza", "attrs": { "name": "M" } }
//!   GET  /aggregates/:name
//!   GET  /aggregates/:name/:id
//!   GET  /events
//!   GET  /policies
//!   GET  /health

use crate::json_helpers::*;
use crate::runtime::Runtime;
use std::io::{Read, Write, BufRead, BufReader};
use std::net::TcpListener;
use std::cell::RefCell;

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
        handle_connection(stream, &rt);
    }
}

fn handle_connection(mut stream: std::net::TcpStream, rt: &RefCell<Runtime>) {
    let mut reader = BufReader::new(&stream);
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).is_err() { return; }

    let parts: Vec<&str> = request_line.trim().split_whitespace().collect();
    if parts.len() < 2 { return; }
    let method = parts[0];
    let path = parts[1];

    let mut content_length = 0usize;
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header).is_err() { return; }
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

    let (status, body) = route(method, path, &body, rt);
    let resp = format!(
        "HTTP/1.1 {}\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\n\r\n{}",
        status, body.len(), body
    );
    let _ = stream.write_all(resp.as_bytes());
}

pub fn route(
    method: &str, path: &str, body: &str, rt: &RefCell<Runtime>,
) -> (&'static str, String) {
    let seg: Vec<&str> = path.trim_matches('/').split('/').collect();

    match (method, seg.as_slice()) {
        ("GET", ["health"]) => ("200 OK", r#"{"status":"ok"}"#.into()),

        ("GET", ["domain"]) => {
            let rt = rt.borrow();
            let aggs: Vec<String> = rt.domain.aggregates.iter().map(|a| {
                let cmds: Vec<String> = a.commands.iter()
                    .map(|c| format!(r#""{}""#, c.name)).collect();
                format!(r#"{{"name":"{}","description":{},"commands":[{}]}}"#,
                    a.name, json_str(a.description.as_deref().unwrap_or("")), cmds.join(","))
            }).collect();
            ("200 OK", format!(r#"{{"name":"{}","aggregates":[{}]}}"#, rt.domain.name, aggs.join(",")))
        }

        ("POST", ["dispatch"]) => {
            let (cmd, attrs) = parse_dispatch_body(body);
            let mut rt = rt.borrow_mut();
            match rt.dispatch(&cmd, attrs) {
                Ok(r) => {
                    let evt = r.event.as_ref().map(|e| format!(r#","event":"{}""#, e.name)).unwrap_or_default();
                    ("200 OK", format!(r#"{{"ok":true,"aggregate_type":"{}","aggregate_id":"{}"{}}}"#,
                        r.aggregate_type, r.aggregate_id, evt))
                }
                Err(e) => ("422 Unprocessable Entity", format!(r#"{{"ok":false,"error":"{}"}}"#, e)),
            }
        }

        ("GET", ["aggregates", name]) => {
            let rt = rt.borrow();
            let items = rt.all(name);
            let rows: Vec<String> = items.iter().map(|s|
                format!(r#"{{"id":"{}",{}}}"#, s.id, value_map_to_json(&s.fields))
            ).collect();
            ("200 OK", format!(r#"{{"aggregate":"{}","count":{},"records":[{}]}}"#, name, rows.len(), rows.join(",")))
        }

        ("GET", ["aggregates", name, id]) => {
            let rt = rt.borrow();
            match rt.find(name, id) {
                Some(s) => ("200 OK", format!(r#"{{"id":"{}",{}}}"#, s.id, value_map_to_json(&s.fields))),
                None => ("404 Not Found", format!(r#"{{"error":"not found","aggregate":"{}","id":"{}"}}"#, name, id)),
            }
        }

        ("GET", ["events"]) => {
            let rt = rt.borrow();
            let evts: Vec<String> = rt.event_bus.events().iter().map(|e|
                format!(r#"{{"name":"{}","aggregate_type":"{}","aggregate_id":"{}"}}"#, e.name, e.aggregate_type, e.aggregate_id)
            ).collect();
            ("200 OK", format!(r#"{{"count":{},"events":[{}]}}"#, evts.len(), evts.join(",")))
        }

        ("GET", ["policies"]) => {
            let rt = rt.borrow();
            let pols: Vec<String> = rt.policy_engine.bindings().iter().map(|b|
                format!(r#"{{"name":"{}","on_event":"{}","trigger_command":"{}"}}"#, b.name, b.on_event, b.trigger_command)
            ).collect();
            ("200 OK", format!(r#"{{"count":{},"policies":[{}]}}"#, pols.len(), pols.join(",")))
        }

        _ => ("404 Not Found", r#"{"error":"not found"}"#.into()),
    }
}
