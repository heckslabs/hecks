// [antibody-exempt: rust/src/server/multi.rs — storehouse engine HTTP serve
//  transport. Kernel Rust : the multi-domain server that BOOTS and EXECUTES
//  bluebooks over HTTP ; it cannot itself be bluebook vocabulary (it IS the
//  runtime that runs them). Permanent engine-surface exemption — Chris chose
//  the registry/permanent path, 2026-06-25.]
//! Multi-domain server — serves N bluebook domains under one API
//!
//! Scans a directory for *.bluebook files, boots a Runtime for each,
//! and serves them all with domain-namespaced routes.
//!
//! Usage:
//!   storehouse serve path/to/hecks/ 3100
//!
//! Routes:
//!   GET  /                         HTML index of all domains
//!   GET  /domains                  JSON list of all domain names
//!   POST /domains/:name/dispatch   Dispatch a command to a domain
//!   GET  /domains/:name/aggregates List aggregates for a domain

use crate::runtime::acl_readmodel::{self, DoorPosture};
use crate::runtime::{Runtime, Value};
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

/// Process-wide served root, set once at serve start. The `/source` route
/// reads the raw .bluebook files from here on demand — the serve is one
/// dir per process, so a OnceLock is the honest home ; no per-request
/// param threading through handle_multi / route_multi.
static SERVED_ROOT: std::sync::OnceLock<String> = std::sync::OnceLock::new();

/// Read + concatenate every .bluebook under the served root (skipping
/// data/, node_modules/, target/, dotfiles) — the RAW source behind the
/// domain, for the UI's "view source" (the actual file text, never a
/// reconstruction). Each file gets a `# ── name ──` header.
fn read_bluebook_source() -> String {
    let root = match SERVED_ROOT.get() {
        Some(r) => r,
        None => return String::new(),
    };
    let mut files: Vec<std::path::PathBuf> = Vec::new();
    collect_bluebook_files(Path::new(root), &mut files);
    files.sort();
    let mut out = String::new();
    for f in files {
        if let Ok(src) = std::fs::read_to_string(&f) {
            let name = f.file_name().unwrap_or_default().to_string_lossy();
            out.push_str(&format!("# ── {} ──\n{}\n\n", name, src));
        }
    }
    out
}

fn collect_bluebook_files(root: &Path, out: &mut Vec<std::path::PathBuf>) {
    let entries = match std::fs::read_dir(root) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        if path.is_dir() {
            if name == "data" || name == "node_modules" || name == "target" {
                continue;
            }
            collect_bluebook_files(&path, out);
        } else if path.extension().map(|e| e == "bluebook").unwrap_or(false) {
            out.push(path);
        }
    }
}

/// Boot all bluebooks in a directory and serve them
pub fn serve_directory(dir: &str, port: u16) {
    let _ = SERVED_ROOT.set(dir.to_string());
    // Load every hecksagon (incl. .family / .adapter) under the served tree
    // AND under the running repo FIRST — the domain runtimes boot WITH them
    // attached (boot_served_runtime), so ensure_outbox_substrate merges the
    // OutboundEvent outbox and the effect drain resolves each adapter's
    // handler. Loading them AFTER the runtimes (as before) left every served
    // runtime hecksagon-less, so declared effect ports never fired. They also
    // register their :web routes (living_diagram, etc.).
    let mut hecksagons = load_all_hecksagons(dir);
    if let Some(repo_root) = repo_root_of_binary() {
        hecksagons.extend(load_all_hecksagons(repo_root.to_str().unwrap_or(".")));
    }

    let mut runtimes = load_all_domains(dir, &hecksagons);
    if runtimes.is_empty() {
        eprintln!("No .bluebook files found in {}", dir);
        std::process::exit(1);
    }

    let repo_root = repo_root_of_binary().unwrap_or_else(|| std::path::PathBuf::from("."));
    let served_dir = std::fs::canonicalize(dir).unwrap_or_else(|_| std::path::PathBuf::from(dir));
    let mut registry = WebRegistry::scan(&hecksagons, &repo_root, &served_dir);

    let names: Vec<String> = runtimes.keys().cloned().collect();
    eprintln!("Hecks Life — {} domains, {} :web routes on http://localhost:{}",
        names.len(), registry.len(), port);
    for name in &names {
        eprintln!("  domain: {}", name);
    }
    for route in registry.routes() {
        eprintln!("  :web   : {} {} ({})", route.method, route.pattern, route.source_hecksagon);
    }

    // Door posture — read from the SERVED root's OWN `.world` only (the
    // sibling-union walk in attach_world_adapter_bindings must never decide
    // the door : a stray sibling `.world` would flip it). Absent = Open,
    // which keeps every existing deployment byte-identical.
    // (world::attach is host-only fs plumbing, cfg-gated out of the wasm
    // worker build — which never runs serve_directory ; wasm gets Open.)
    #[cfg(not(target_arch = "wasm32"))]
    let posture = crate::world::attach::door_posture_for_root(dir);
    #[cfg(target_arch = "wasm32")]
    let posture = DoorPosture::Open;
    if posture == DoorPosture::Governed {
        eprintln!("  door   : governed (per-request bearer principals, fail-closed)");
    }

    let addr = format!("0.0.0.0:{}", port);
    let listener = TcpListener::bind(&addr).unwrap_or_else(|e| {
        eprintln!("Cannot bind {}: {}", addr, e);
        std::process::exit(1);
    });

    // Hot reload — the refresh must show the bluebook as it IS. Before
    // each request, fingerprint the served tree (paths + mtimes of every
    // .bluebook / .hecksagon / .family / .adapter / .world) ; when it
    // changes, re-boot the domains from disk. Records survive : reload
    // re-hydrates from the same heki stores. A half-saved or invalid
    // edit must NEVER take the server down — the reload is panic-guarded
    // and keeps the previous runtimes when the fresh tree yields nothing.
    let mut fingerprint = tree_fingerprint(dir);
    for stream in listener.incoming().flatten() {
        let fresh = tree_fingerprint(dir);
        if fresh != fingerprint {
            fingerprint = fresh;
            let reloaded = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let mut hexes = load_all_hecksagons(dir);
                if let Some(rr) = repo_root_of_binary() {
                    hexes.extend(load_all_hecksagons(rr.to_str().unwrap_or(".")));
                }
                let rts = load_all_domains(dir, &hexes);
                let reg = WebRegistry::scan(&hexes, &repo_root, &served_dir);
                (rts, reg)
            }));
            match reloaded {
                Ok((rts, reg)) if !rts.is_empty() => {
                    let names: Vec<String> = rts.keys().cloned().collect();
                    runtimes = rts;
                    registry = reg;
                    eprintln!("reload : bluebook tree changed — {} domain(s) re-booted : {}",
                        names.len(), names.join(", "));
                }
                Ok(_) => {
                    eprintln!("reload : tree changed but no valid bluebooks parsed — keeping previous domains");
                }
                Err(_) => {
                    eprintln!("reload : parse panicked on the fresh tree — keeping previous domains");
                }
            }
        }
        handle_multi(stream, &runtimes, &registry, posture);
    }
}

/// Fingerprint of every domain-definition file under the served tree —
/// path + mtime of each .bluebook / .hecksagon / .family / .adapter /
/// .world, folded into one u64. Same walk-skips as walk_hecksagons
/// (data/, node_modules/, target/, dotfiles). Adding, editing, or
/// deleting a file all change the hash.
fn tree_fingerprint(dir: &str) -> u64 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::Hasher;
    let mut hasher = DefaultHasher::new();
    fingerprint_walk(Path::new(dir), &mut hasher);
    hasher.finish()
}

fn fingerprint_walk(root: &Path, hasher: &mut std::collections::hash_map::DefaultHasher) {
    use std::hash::Hash;
    let entries = match std::fs::read_dir(root) {
        Ok(e) => e,
        Err(_) => return,
    };
    let mut paths: Vec<std::path::PathBuf> = entries.flatten().map(|e| e.path()).collect();
    paths.sort();
    for path in paths {
        let name = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        if path.is_dir() {
            if name == "data" || name == "node_modules" || name == "target" {
                continue;
            }
            fingerprint_walk(&path, hasher);
        } else if path
            .extension()
            .map(|e| {
                e == "bluebook" || e == "hecksagon" || e == "family" || e == "adapter" || e == "world"
            })
            .unwrap_or(false)
        {
            path.to_string_lossy().hash(hasher);
            if let Ok(meta) = std::fs::metadata(&path) {
                if let Ok(mtime) = meta.modified() {
                    if let Ok(d) = mtime.duration_since(std::time::UNIX_EPOCH) {
                        d.as_nanos().hash(hasher);
                    }
                }
                meta.len().hash(hasher);
            }
        }
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
        } else if path.extension().map(|e| e == "hecksagon" || e == "family" || e == "adapter").unwrap_or(false) {
            // .family / .adapter are framework vocabulary parsed through the
            // SAME hecksagon parser — serve needs them so a domain runtime
            // can resolve an effect bind's adapter handler (mirrors the cli's
            // load_all_hecksagons). Without them DiskBuffer & friends never
            // resolve and declared effect ports silently no-op under serve.
            if let Ok(source) = std::fs::read_to_string(&path) {
                let hex = hecksagon_parser::parse(&source);
                // A .hecksagon carries a top-level name ; a .adapter / .family
                // parses to an EMPTY top-level name but a populated adapters /
                // families vec. Key those by the first adapter / family name so
                // they aren't dropped — the runtime needs them attached to
                // resolve an effect bind's adapter -> family -> verb chain
                // (record_effect_outbound). Distinct names never collide.
                let key = if !hex.name.is_empty() {
                    hex.name.clone()
                } else if let Some(a) = hex.adapters.first() {
                    a.name.clone()
                } else if let Some(f) = hex.families.first() {
                    f.name.clone()
                } else {
                    String::new()
                };
                if !key.is_empty() {
                    map.insert(key, hex);
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
fn load_all_domains(
    dir: &str,
    hecksagons: &HashMap<String, Hecksagon>,
) -> HashMap<String, RefCell<Runtime>> {
    let mut map = HashMap::new();
    let data_dir = format!("{}/data", dir.trim_end_matches('/'));

    let dir_path = std::fs::canonicalize(dir)
        .unwrap_or_else(|_| std::path::PathBuf::from(dir));
    let served_root = dir_path.to_string_lossy().into_owned();
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
            let rt = boot_served_runtime(merged, &data_dir, &served_root, hecksagons);
            map.insert(name, RefCell::new(rt));
        }
    } else {
        // LEGACY mode — each .bluebook is its own domain.
        walk_bluebooks(&dir_path, &data_dir, &served_root, hecksagons, &mut map);
    }
    map
}

/// Boot a served domain runtime the way the CLI dispatch path does
/// (`dispatch_hecksagon`) : `boot_with_hecksagons` so the attached hecksagons
/// let `ensure_outbox_substrate` merge the OutboundEvent outbox and the effect
/// drain resolve each adapter's handler ; set the `aggregates_root` a
/// re-entering handler shells against ; fold the per-deployment `.world`
/// config onto the adapters so a drained handler gets its env. Before this a
/// served runtime booted hecksagon-less (`boot_with_data_dir`), so it had no
/// outbox and no adapters and every declared effect port silently no-op'd.
fn boot_served_runtime(
    domain: crate::ir::Domain,
    data_dir: &str,
    served_root: &str,
    hecksagons: &HashMap<String, Hecksagon>,
) -> Runtime {
    let hex: Vec<Hecksagon> = hecksagons.values().cloned().collect();
    let mut rt = Runtime::boot_with_hecksagons(domain, Some(data_dir.to_string()), hex);
    rt.aggregates_root = std::fs::canonicalize(served_root)
        .ok()
        .map(|p| p.to_string_lossy().into_owned())
        .or_else(|| Some(served_root.to_string()));
    // World attach is host-only (it walks .world files off disk) ; a wasm
    // worker never runs serve_directory, and crate::world::attach is itself
    // cfg-gated out of the wasm build, so gate the calls to match.
    #[cfg(not(target_arch = "wasm32"))]
    {
        crate::world::attach::attach_world_servers(&mut rt, served_root);
        crate::world::attach::attach_world_adapter_bindings(&mut rt, served_root);
    }
    rt
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
    served_root: &str,
    hecksagons: &HashMap<String, Hecksagon>,
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
            walk_bluebooks(&path, data_dir, served_root, hecksagons, map);
        } else if path.extension().map(|e| e == "bluebook").unwrap_or(false) {
            if let Ok(source) = std::fs::read_to_string(&path) {
                let domain = parser::parse(&source);
                if domain.name.is_empty() { continue; }
                let name = domain.name.clone();
                let rt = boot_served_runtime(domain, data_dir, served_root, hecksagons);
                map.insert(name, RefCell::new(rt));
            }
        }
    }
}

fn handle_multi(
    mut stream: std::net::TcpStream,
    runtimes: &HashMap<String, RefCell<Runtime>>,
    registry: &WebRegistry,
    posture: DoorPosture,
) {
    let req = match read_request(&stream) {
        Some(r) => r,
        None => return,
    };
    let (method, path, body) = (req.method, req.path, req.body);
    let bearer = req.bearer;

    // First : try the bluebook-declared :web routes. The hecksagons
    // are the source of truth for route registration (i527). When
    // multiple routes match (e.g. a literal /diagram/_all/graph.json
    // and a parametric /diagram/:domain_name/graph.json), try each
    // in turn ; the first whose render succeeds wins. Render returns
    // None when its serializer's preconditions don't match (e.g. the
    // graph_projection serializer can't resolve `_all` to a runtime).
    let web_matches = registry.resolve_all(&method, &path);

    // Under a GOVERNED door the :web template projections — read-only
    // renders that BYPASS routes::route entirely — gate HERE, the earliest
    // common point, ONCE, over the synthetic read phrase
    // `Web::Projection.render` (no :web route declares a backing query
    // today ; when one does, its query FQN becomes the phrase). Under an
    // OPEN door the renders are untouched.
    if !web_matches.is_empty() && posture == DoorPosture::Governed {
        if let Some(rt) = gate_runtime(runtimes) {
            let mut gate_attrs: HashMap<String, Value> = HashMap::new();
            acl_readmodel::stamp_principal_from_request(
                &mut gate_attrs, bearer.as_deref(), posture,
            );
            let verdict = rt.borrow_mut()
                .authorize_entry("Web::Projection.render", &mut gate_attrs);
            if let Err(e) = verdict {
                write_response(&mut stream, "403 Forbidden", &format!(
                    r#"{{"ok":false,"error":{},"command":"Web::Projection.render"}}"#,
                    crate::json_helpers::json_str(&e.to_string())
                ));
                return;
            }
        }
    }

    let mut served = false;
    for (route, params) in web_matches {
        if let Some((content_type, body)) =
            crate::server::web_adapter::render(
                route, &params, runtimes, &registry.served_dir, &registry.repo_root,
            )
        {
            write_response_typed(&mut stream, "200 OK", &content_type, &body);
            served = true;
            break;
        }
    }
    if served { return; }

    let seg: Vec<&str> = path.trim_matches('/').split('/').collect();
    let (status, resp_body) =
        route_multi(&method, &seg, &body, bearer.as_deref(), posture, runtimes);
    write_response(&mut stream, status, &resp_body);
}

/// The runtime door-level gates run against : the primary/sole served
/// runtime in the common governed deployment (primary-bluebook mode boots
/// exactly one) ; alphabetically-first for determinism when several
/// legacy-mode domains are served.
fn gate_runtime(
    runtimes: &HashMap<String, RefCell<Runtime>>,
) -> Option<&RefCell<Runtime>> {
    runtimes.keys().min().and_then(|k| runtimes.get(k))
}

fn write_response_typed(
    stream: &mut std::net::TcpStream, status: &str, content_type: &str, body: &str,
) {
    use std::io::Write;
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

fn route_multi(
    method: &str, seg: &[&str], body: &str,
    bearer: Option<&str>, posture: DoorPosture,
    runtimes: &HashMap<String, RefCell<Runtime>>,
) -> (&'static str, String) {
    match (method, seg) {
        ("OPTIONS", _) => ("204 No Content", String::new()),

        // The HTML index, the domain list, and the per-domain page are
        // introspection over the whole served universe — under a GOVERNED
        // door they answer 403 wholesale, same ruling as routes::route's
        // /domain / /events / /policies (readers enter through aggregate
        // queries). Under an OPEN door they are unchanged.
        ("GET", [""]) | ("GET", []) | ("GET", ["domains"]) | ("GET", ["domains", _])
        | ("GET", ["domains", _, "source"])
            if posture == DoorPosture::Governed =>
        {
            ("403 Forbidden", format!(
                r#"{{"ok":false,"error":"introspection is closed under a governed door","command":{}}}"#,
                crate::json_helpers::json_str(&format!("/{}", seg.join("/")))
            ))
        }

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

        // Raw bluebook source — the actual .bluebook text behind the domain,
        // for the UI's "view source". More specific than the delegation arm
        // below, so it must precede it.
        ("GET", ["domains", name, "source"]) => {
            match runtimes.get(*name) {
                Some(_) => (
                    "200 OK",
                    format!(r#"{{"source":{}}}"#, crate::json_helpers::json_str(&read_bluebook_source())),
                ),
                None => ("404 Not Found", format!(r#"{{"error":"domain not found","name":"{}"}}"#, name)),
            }
        }

        ("GET", ["domains", name, rest @ ..]) |
        ("POST", ["domains", name, rest @ ..]) => {
            match runtimes.get(*name) {
                Some(rt) => {
                    let sub = format!("/{}", rest.join("/"));
                    routes::route(method, &sub, body, bearer, posture, rt)
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

