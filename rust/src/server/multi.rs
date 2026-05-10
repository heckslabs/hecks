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
use crate::hecksagon_parser;
use crate::hecksagon_ir::Hecksagon;
use super::{read_request, write_response};
use super::routes;
use super::html;
use super::html_domain;
use super::web_adapter::WebRegistry;
use std::cell::RefCell;
use std::collections::HashMap;
use std::net::TcpListener;
use std::path::Path;

/// Boot all bluebooks in a directory and serve them
pub fn serve_directory(dir: &str, port: u16) {
    let runtimes = load_all_domains(dir);
    if runtimes.is_empty() {
        eprintln!("No .bluebook files found in {}", dir);
        std::process::exit(1);
    }

    // Load every hecksagon under the served tree AND under the
    // running repo (so framework-side hecksagons like
    // runtime/living_diagram/living_diagram.hecksagon register their
    // :web routes too, even when the served dir is bin-buddy).
    let mut hecksagons = load_all_hecksagons(dir);
    if let Some(repo_root) = repo_root_of_binary() {
        hecksagons.extend(load_all_hecksagons(repo_root.to_str().unwrap_or(".")));
    }
    let repo_root = repo_root_of_binary().unwrap_or_else(|| std::path::PathBuf::from("."));
    let registry = WebRegistry::scan(&hecksagons, &repo_root);

    let names: Vec<String> = runtimes.keys().cloned().collect();
    eprintln!("Hecks Life — {} domains, {} :web routes on http://localhost:{}",
        names.len(), registry.len(), port);
    for name in &names {
        eprintln!("  domain: {}", name);
    }
    for route in registry.routes() {
        eprintln!("  :web   : {} {} ({})", route.method, route.pattern, route.source_hecksagon);
    }

    let addr = format!("0.0.0.0:{}", port);
    let listener = TcpListener::bind(&addr).unwrap_or_else(|e| {
        eprintln!("Cannot bind {}: {}", addr, e);
        std::process::exit(1);
    });

    for stream in listener.incoming().flatten() {
        handle_multi(stream, &runtimes, &registry);
    }
}

/// Walk the same tree as load_all_domains for `.hecksagon` files.
fn load_all_hecksagons(dir: &str) -> HashMap<String, Hecksagon> {
    let mut map = HashMap::new();
    walk_hecksagons(Path::new(dir), &mut map);
    map
}

fn walk_hecksagons(root: &Path, map: &mut HashMap<String, Hecksagon>) {
    let entries = match std::fs::read_dir(root) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name_os = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
        if name_os.starts_with('.') { continue; }
        if path.is_dir() {
            if name_os == "data" || name_os == "node_modules" || name_os == "target" {
                continue;
            }
            walk_hecksagons(&path, map);
        } else if path.extension().map(|e| e == "hecksagon").unwrap_or(false) {
            if let Ok(source) = std::fs::read_to_string(&path) {
                let hex = hecksagon_parser::parse(&source);
                if !hex.name.is_empty() {
                    map.insert(hex.name.clone(), hex);
                }
            }
        }
    }
}

/// Resolve the repo root by walking up from the binary's location
/// looking for a `runtime/` directory. Best-effort — falls back to
/// the current working directory if the heuristic fails.
fn repo_root_of_binary() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let mut cur = exe.parent()?.to_path_buf();
    for _ in 0..6 {
        if cur.join("runtime").is_dir() && cur.join("hecks_conception").is_dir() {
            return Some(cur);
        }
        cur = cur.parent()?.to_path_buf();
    }
    None
}

/// i241 primary-bluebook convention. When `serve <dir>` finds a
/// `<dirname>.bluebook` at the top level (the primary), every other
/// *.bluebook in the tree merges its aggregates / policies / fixtures
/// / sections / process_managers / cadences / block_grammars into
/// the primary. The primary owns name + vision + category +
/// entrypoint. This is the convention bin-buddy and other application
/// repos follow (one product = one domain, split into per-aggregate
/// files for tractability).
///
/// When NO primary exists at the root, fall back to legacy mode :
/// each top-level *.bluebook becomes its own domain (catalog-style,
/// for trees like hecks_conception/catalog where each file is a
/// self-contained domain).
fn load_all_domains(dir: &str) -> HashMap<String, RefCell<Runtime>> {
    let mut map = HashMap::new();
    let data_dir = format!("{}/data", dir.trim_end_matches('/'));

    let dir_path = std::fs::canonicalize(dir)
        .unwrap_or_else(|_| std::path::PathBuf::from(dir));
    let dir_basename = dir_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("");
    let primary_path = dir_path.join(format!("{}.bluebook", dir_basename));

    if primary_path.exists() {
        // PRIMARY mode — merge tree into one domain.
        let merged = merge_tree(&dir_path, &primary_path);
        if !merged.name.is_empty() {
            let name = merged.name.clone();
            let rt = Runtime::boot_with_data_dir(merged, Some(data_dir.clone()));
            map.insert(name, RefCell::new(rt));
        }
    } else {
        // LEGACY mode — each .bluebook is its own domain.
        walk_bluebooks(&dir_path, &data_dir, &mut map);
    }
    map
}

/// Recursively read every *.bluebook under `dir` (other than the
/// primary itself), parse it, and merge its top-level Vec contents
/// into the primary Domain. Files that fail to read are silently
/// skipped — the operator already gets a parse error from `validate`.
fn merge_tree(dir: &std::path::Path, primary_path: &std::path::Path) -> crate::ir::Domain {
    let primary_src = std::fs::read_to_string(primary_path)
        .expect("primary bluebook must be readable");
    let mut merged = parser::parse(&primary_src);

    let mut child_paths: Vec<std::path::PathBuf> = Vec::new();
    collect_bluebooks(dir, primary_path, &mut child_paths);
    child_paths.sort(); // deterministic order — diagrams render the same every boot

    for path in child_paths {
        if let Ok(source) = std::fs::read_to_string(&path) {
            let child = parser::parse(&source);
            merged.aggregates.extend(child.aggregates);
            merged.policies.extend(child.policies);
            merged.fixtures.extend(child.fixtures);
            merged.sections.extend(child.sections);
            merged.process_managers.extend(child.process_managers);
            merged.cadences.extend(child.cadences);
            merged.block_grammars.extend(child.block_grammars);
        }
    }
    merged
}

fn collect_bluebooks(
    dir: &std::path::Path,
    skip: &std::path::Path,
    out: &mut Vec<std::path::PathBuf>,
) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name_os = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
        if name_os.starts_with('.') { continue; }
        if path.is_dir() {
            if name_os == "data" || name_os == "node_modules" || name_os == "target" {
                continue;
            }
            collect_bluebooks(&path, skip, out);
        } else if path.extension().map(|e| e == "bluebook").unwrap_or(false) && path != skip {
            out.push(path);
        }
    }
}

/// Legacy walker (no-primary mode) — each *.bluebook is its own Runtime.
fn walk_bluebooks(
    root: &std::path::Path,
    data_dir: &str,
    map: &mut HashMap<String, RefCell<Runtime>>,
) {
    let entries = match std::fs::read_dir(root) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name_os = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
        if name_os.starts_with('.') { continue; }
        if path.is_dir() {
            // Skip data directories — they hold heki snapshots, not source.
            if name_os == "data" || name_os == "node_modules" || name_os == "target" {
                continue;
            }
            walk_bluebooks(&path, data_dir, map);
        } else if path.extension().map(|e| e == "bluebook").unwrap_or(false) {
            if let Ok(source) = std::fs::read_to_string(&path) {
                let domain = parser::parse(&source);
                if domain.name.is_empty() { continue; }
                let name = domain.name.clone();
                let rt = Runtime::boot_with_data_dir(domain, Some(data_dir.to_string()));
                map.insert(name, RefCell::new(rt));
            }
        }
    }
}

fn handle_multi(
    mut stream: std::net::TcpStream,
    runtimes: &HashMap<String, RefCell<Runtime>>,
    registry: &WebRegistry,
) {
    let (method, path, body) = match read_request(&stream) {
        Some(r) => r,
        None => return,
    };

    // First : try the bluebook-declared :web routes. The hecksagons
    // are the source of truth for route registration (i527). When
    // multiple routes match (e.g. a literal /diagram/_all/graph.json
    // and a parametric /diagram/:domain_name/graph.json), try each
    // in turn ; the first whose render succeeds wins. Render returns
    // None when its serializer's preconditions don't match (e.g. the
    // graph_projection serializer can't resolve `_all` to a runtime).
    let mut served = false;
    for (route, params) in registry.resolve_all(&method, &path) {
        if let Some((content_type, body)) =
            crate::server::web_adapter::render(route, &params, runtimes)
        {
            write_response_typed(&mut stream, "200 OK", &content_type, &body);
            served = true;
            break;
        }
    }
    if served { return; }

    let seg: Vec<&str> = path.trim_matches('/').split('/').collect();
    let (status, resp_body) = route_multi(&method, &seg, &body, runtimes);
    write_response(&mut stream, status, &resp_body);
}

fn write_response_typed(
    stream: &mut std::net::TcpStream, status: &str, content_type: &str, body: &str,
) {
    use std::io::Write;
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

        // /diagram/:name routes are now declared in
        // runtime/living_diagram/living_diagram.hecksagon and
        // dispatched through the :web adapter registry above.
        // Empty-stub left here for legacy : if registry resolution
        // somehow misses, the 404 below fires.
        ("GET", ["__diagram_legacy_disabled", name]) => {
            match runtimes.get(*name) {
                Some(_rt) => ("200 OK", String::new()),
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

