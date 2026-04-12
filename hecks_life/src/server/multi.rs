//! Multi-domain server — serves N bluebook domains under one API
//!
//! Scans a directory for *.bluebook files, boots a Runtime for each,
//! and serves them all with domain-namespaced routes.
//!
//! Usage:
//!   hecks-life serve path/to/hecks/ 3100
//!
//! Routes:
//!   GET  /                         HTML index of all domains
//!   GET  /domains                  JSON list of all domain names
//!   POST /domains/:name/dispatch   Dispatch a command to a domain
//!   GET  /domains/:name/aggregates List aggregates for a domain

use crate::runtime::Runtime;
use crate::parser;
use super::{read_request, write_response};
use super::routes;
use super::html;
use super::html_domain;
use std::cell::RefCell;
use std::collections::HashMap;
use std::net::TcpListener;

/// Boot all bluebooks in a directory and serve them
pub fn serve_directory(dir: &str, port: u16) {
    let runtimes = load_all_domains(dir);
    if runtimes.is_empty() {
        eprintln!("No .bluebook files found in {}", dir);
        std::process::exit(1);
    }

    let names: Vec<String> = runtimes.keys().cloned().collect();
    eprintln!("Hecks Life — {} domains on http://localhost:{}", names.len(), port);
    for name in &names {
        eprintln!("  {}", name);
    }

    let addr = format!("0.0.0.0:{}", port);
    let listener = TcpListener::bind(&addr).unwrap_or_else(|e| {
        eprintln!("Cannot bind {}: {}", addr, e);
        std::process::exit(1);
    });

    for stream in listener.incoming().flatten() {
        handle_multi(stream, &runtimes);
    }
}

fn load_all_domains(dir: &str) -> HashMap<String, RefCell<Runtime>> {
    let mut map = HashMap::new();
    let entries = std::fs::read_dir(dir).unwrap_or_else(|e| {
        eprintln!("Cannot read directory {}: {}", dir, e);
        std::process::exit(1);
    });

    let data_dir = format!("{}/data", dir.trim_end_matches('/'));

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().map(|e| e == "bluebook").unwrap_or(false) {
            if let Ok(source) = std::fs::read_to_string(&path) {
                let domain = parser::parse(&source);
                let name = domain.name.clone();
                let rt = Runtime::boot_with_data_dir(domain, Some(data_dir.clone()));
                map.insert(name, RefCell::new(rt));
            }
        }
    }
    map
}

fn handle_multi(
    mut stream: std::net::TcpStream,
    runtimes: &HashMap<String, RefCell<Runtime>>,
) {
    let (method, path, body) = match read_request(&stream) {
        Some(r) => r,
        None => return,
    };

    let seg: Vec<&str> = path.trim_matches('/').split('/').collect();
    let (status, resp_body) = route_multi(&method, &seg, &body, runtimes);
    write_response(&mut stream, status, &resp_body);
}

fn route_multi(
    method: &str, seg: &[&str], body: &str,
    runtimes: &HashMap<String, RefCell<Runtime>>,
) -> (&'static str, String) {
    match (method, seg) {
        ("OPTIONS", _) => ("204 No Content", String::new()),

        ("GET", [""]) | ("GET", []) => {
            ("200 OK", html::generate_index(runtimes))
        }

        ("GET", ["domains"]) => {
            let list: Vec<String> = domain_list(runtimes);
            let items: Vec<String> = list.iter()
                .map(|n| format!(r#""{}""#, n)).collect();
            ("200 OK", format!(
                r#"{{"count":{},"domains":[{}]}}"#, items.len(), items.join(",")
            ))
        }

        ("GET", ["domains", name]) => {
            match runtimes.get(*name) {
                Some(rt) => ("200 OK", html_domain::generate_domain_page(name, rt, runtimes)),
                None => ("404 Not Found", format!(
                    r#"{{"error":"domain not found","name":"{}"}}"#, name
                )),
            }
        }

        ("GET", ["domains", name, rest @ ..]) |
        ("POST", ["domains", name, rest @ ..]) => {
            match runtimes.get(*name) {
                Some(rt) => {
                    let sub = format!("/{}", rest.join("/"));
                    routes::route(method, &sub, body, rt)
                }
                None => ("404 Not Found", format!(
                    r#"{{"error":"domain not found","name":"{}"}}"#, name
                )),
            }
        }

        // Fall through to single-domain style for health
        ("GET", ["health"]) => ("200 OK", r#"{"status":"ok"}"#.into()),

        _ => ("404 Not Found", r#"{"error":"not found"}"#.into()),
    }
}

fn domain_list(runtimes: &HashMap<String, RefCell<Runtime>>) -> Vec<String> {
    let mut names: Vec<String> = runtimes.keys().cloned().collect();
    names.sort();
    names
}

