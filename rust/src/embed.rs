//! embed — the one-shot, in-process dispatch/query entry (2026-07-03).
//!
//! Purpose: ONE panic-safe, gate-honest code path that drives a domain
//! in-process. A native binding (the magnus Ruby ext, and any other embedder)
//! calls [`dispatch_once`] / [`query_once`]; the CLI's cold door calls the SAME
//! shared core ([`authorized_dispatch`] / [`gated_query`]) on its own booted
//! runtime. One implementation of the gate+dispatch means the CLI, the HTTP
//! door, and a future FFI binding all admit and deny identically — the store,
//! the corpus, and the authorization verdict are resolved the same way for every
//! caller.
//!
//! Usage:
//! ```no_run
//! use std::collections::HashMap;
//! use storehouse::embed::{dispatch_once, Principal};
//! let mut attrs = HashMap::new();
//! attrs.insert("ref".to_string(), "o-1".to_string());
//! let verdict = dispatch_once("/path/to/root", "Pizzas::Order.PlaceOrder", attrs, Principal::System);
//! assert_eq!(verdict["ok"], true);
//! ```
//!
//! [antibody-exempt: rust/src/embed.rs + rust/src/lib.rs + rust/cli/src/main.rs + tests — kernel-floor embed entry + CLI refactor to share it, authorized by Chris 2026-07-03]
//! [loc-ratchet-override: embed::dispatch_once — shared one-shot entry for CLI + native bindings; authorized by Chris 2026-07-03]

use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};

use serde_json::json;

use crate::hecksagon_ir::Hecksagon;
use crate::runtime::{acl_readmodel, Runtime, Value};

/// The caller identity at the door. Re-exported from the runtime's authorization
/// read-model so the embed boundary and the gate agree on one type.
pub use crate::runtime::acl_readmodel::Principal;

// ============================================================
// Corpus + store resolution
// ------------------------------------------------------------
// Lifted verbatim from the cold CLI (find_world_heki_dir / load_all_hecksagons)
// so an embedder resolves the SAME domain and the SAME .heki store the CLI does.
// Single implementation — the CLI now delegates here.
// ============================================================

/// The write/read store dir for `aggregates_path`: the `.world` realm/default
/// store, else a legacy `heki { dir }`, else the canonical info dir. Always
/// resolves (never `None`) — mirror of the old cli `find_world_heki_dir`.
pub fn data_dir(aggregates_path: &str) -> String {
    if let Some(world_dir) = crate::heki::resolve_world_store_dir(aggregates_path) {
        return world_dir;
    }
    if let Some(world_dir) = read_world_heki_dir(aggregates_path) {
        return world_dir;
    }
    crate::heki::resolve_info_dir().to_string_lossy().into_owned()
}

/// Legacy explicit `heki { dir }` relative to the world file (fuzzer isolation).
fn read_world_heki_dir(aggregates_path: &str) -> Option<String> {
    use std::path::Path;
    let agg = Path::new(aggregates_path);
    let world_dir = if agg.is_dir() { agg.parent()? } else { agg.parent()?.parent()? };
    let world_file = std::fs::read_dir(world_dir).ok()?
        .filter_map(|e| e.ok())
        .find(|e| e.path().extension().map_or(false, |ext| ext == "world"))?
        .path();
    let source = std::fs::read_to_string(&world_file).ok()?;
    let world = crate::world::parser::parse(&source);
    let dir_value = world.config_for("heki").and_then(|c| c.get("dir"))?;
    let resolved = world_dir.join(dir_value);
    if resolved.exists() { Some(resolved.to_string_lossy().into_owned()) } else { None }
}

fn find_world_file(dir: &std::path::Path) -> Option<std::path::PathBuf> {
    let mut matches: Vec<std::path::PathBuf> = std::fs::read_dir(dir).ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().map(|e| e == "world").unwrap_or(false))
        .collect();
    matches.sort();
    matches.into_iter().next()
}

fn find_world_sqlite_path(agg_dir: &str) -> Option<String> {
    let p = std::path::Path::new(agg_dir);
    let world_path = find_world_file(p).or_else(|| p.parent().and_then(find_world_file))?;
    let content = std::fs::read_to_string(&world_path).ok()?;
    let world = crate::world::parser::parse(&content);
    let cfg = world.config_for("sqlite")?;
    cfg.get("path").or_else(|| cfg.get("file")).or_else(|| cfg.get("db")).map(|s| s.to_string())
}

/// Load every `*.hecksagon` / `*.family` / `*.adapter` reachable from `agg_dir`
/// (itself + sibling repos + top-level buckets), fill sqlite db paths from the
/// world, dedup by canonical path. Mirror of the old cli `load_all_hecksagons`
/// (the lift the run_boot doc comment anticipated).
pub fn load_hecksagons(agg_dir: &str) -> Vec<Hecksagon> {
    let mut out = Vec::new();
    let mut seen: std::collections::HashSet<std::path::PathBuf> = std::collections::HashSet::new();
    fn walk(
        dir: &std::path::Path,
        out: &mut Vec<Hecksagon>,
        seen: &mut std::collections::HashSet<std::path::PathBuf>,
    ) {
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let p = entry.path();
            let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if matches!(name, ".git" | "target" | "information" | ".claude"
                | "node_modules" | "generated" | "fixtures" | "snippets") {
                continue;
            }
            if p.is_dir() {
                walk(&p, out, seen);
            } else if p.extension().map(|e| e == "hecksagon" || e == "family" || e == "adapter").unwrap_or(false) {
                let key = std::fs::canonicalize(&p).unwrap_or_else(|_| p.clone());
                if !seen.insert(key) { continue; }
                if let Ok(source) = std::fs::read_to_string(&p) {
                    out.push(crate::hecksagon_parser::parse(&source));
                }
            }
        }
    }
    walk(std::path::Path::new(agg_dir), &mut out, &mut seen);
    if let Some(repo_root) = crate::heki::repo_root() {
        for sibling in &["miette", "miette_family"] {
            if let Ok(canonical) = std::fs::canonicalize(repo_root.join("..").join(sibling)) {
                if canonical.is_dir() && canonical != std::path::Path::new(agg_dir) {
                    walk(&canonical, &mut out, &mut seen);
                }
            }
        }
        for bucket in &["runtime", "discipline", "codegen", "cli",
                        "integrations", "tools", "capabilities"] {
            let bucket_dir = repo_root.join(bucket);
            if bucket_dir.is_dir() && bucket_dir != std::path::Path::new(agg_dir) {
                walk(&bucket_dir, &mut out, &mut seen);
            }
        }
    }
    if let Some(db) = find_world_sqlite_path(agg_dir) {
        for hex in out.iter_mut() {
            if hex.persistence.as_deref() == Some("sqlite")
                && hex.persistence_option("db").is_none()
            {
                hex.persistence_options.push(("db".to_string(), db.clone()));
            }
        }
    }
    if std::env::var("HECKS_STOREHOUSE_VERBOSE").ok().as_deref() == Some("1") {
        let families: usize = out.iter().map(|h| h.families.len()).sum();
        let adapters: usize = out.iter().map(|h| h.adapters.len()).sum();
        let bindings: usize = out.iter().map(|h| h.bindings.len()).sum();
        eprintln!(
            "[load_all_hecksagons] {} hecksagons, {} families, {} adapters, {} bindings",
            out.len(), families, adapters, bindings
        );
    }
    out
}

// ============================================================
// Principal stamping
// ============================================================

/// Derive the caller principal from the process environment — the cold-CLI
/// door's rule: `HECKS_PRINCIPAL_KIND` forces the kind; else a non-empty
/// `HECKS_SESSION_AUTH_ID` means an agent; else System. The CLI hands this to
/// the shared core so the env-door and the FFI-door stamp identically.
pub fn principal_from_env() -> Principal {
    let auth = std::env::var("HECKS_SESSION_AUTH_ID").unwrap_or_default();
    let kind = std::env::var("HECKS_PRINCIPAL_KIND").unwrap_or_default();
    let is_agent = if !kind.is_empty() { kind == "agent" } else { !auth.is_empty() };
    if is_agent { Principal::Agent { auth_identity_id: auth } } else { Principal::System }
}

/// Stamp the caller principal onto a dispatch's reserved meta attrs, exactly as
/// the HTTP/CLI doors do: System is admitted by origin; an Agent carries its
/// `auth_identity_id` for the PDP to resolve a role.
fn stamp_principal(attrs: &mut HashMap<String, Value>, principal: &Principal) {
    match principal {
        Principal::System => acl_readmodel::stamp_system(attrs),
        Principal::Agent { auth_identity_id } => {
            attrs.insert(acl_readmodel::KIND_KEY.to_string(), Value::Str("agent".to_string()));
            attrs.insert(acl_readmodel::AUTH_KEY.to_string(), Value::Str(auth_identity_id.clone()));
        }
    }
}

// ============================================================
// Boot
// ============================================================

/// Boot a persistence-backed runtime for a root — the lean shared boot (domain +
/// hecksagons + heki store + world adapter bindings + aggregates_root). The cold
/// CLI layers its LLM-provider and world-server registration on top of this for
/// its own dispatch; an embedder gets the pure dispatch substrate.
fn boot_for_dispatch(root: &str) -> Runtime {
    let dd = data_dir(root);
    let combined = if std::path::Path::new(root).is_file() {
        crate::parser::parse(&std::fs::read_to_string(root).unwrap_or_default())
    } else {
        crate::corpus_loader::load_combined_domain(root)
    };
    let hecksagons = load_hecksagons(root);
    let mut rt = Runtime::boot_with_hecksagons(combined, Some(dd), hecksagons);
    // Absolute root so a detach-spawned OOP handler's undefined cwd never matters.
    rt.aggregates_root = std::fs::canonicalize(root).ok()
        .map(|p| p.to_string_lossy().into_owned())
        .or_else(|| Some(root.to_string()));
    crate::world::attach::apply_per_domain_world_dirs(&mut rt, root);
    crate::world::attach::attach_world_adapter_bindings(&mut rt, root);
    rt
}

// ============================================================
// Shared gate+dispatch core — the ONE implementation
// ============================================================

fn state_of(rt: &Runtime, agg_type: &str, agg_id: &str) -> serde_json::Value {
    match rt.find(agg_type, agg_id) {
        Some(s) => {
            let mut map = serde_json::Map::new();
            for (k, v) in &s.fields {
                map.insert(k.clone(), match v {
                    Value::Str(s) => json!(s),
                    Value::Int(n) => json!(n),
                    Value::Bool(b) => json!(b),
                    _ => json!(v.to_string()),
                });
            }
            serde_json::Value::Object(map)
        }
        None => json!({}),
    }
}

/// Stamp + authorize + dispatch a command against an already-booted runtime.
/// The shared gate+dispatch core: both the FFI [`dispatch_once`] and the cold
/// CLI call it, so the authorization verdict and the cascade settle identically.
///
/// Returns the HTTP-door dispatch shape plus the aggregate's post-dispatch
/// `state`: `{ ok, aggregate_type, aggregate_id[, event], cascade, state }`.
/// A governance denial returns `{ ok: false, error, command }` (the door's
/// 403 shape); a non-authz dispatch error returns `{ ok: false, error }`.
pub fn authorized_dispatch(
    rt: &mut Runtime,
    command: &str,
    attrs: HashMap<String, String>,
    principal: Principal,
) -> serde_json::Value {
    let mut rt_attrs: HashMap<String, Value> =
        attrs.into_iter().map(|(k, v)| (k, Value::Str(v))).collect();
    stamp_principal(&mut rt_attrs, &principal);
    if let Err(e) = rt.authorize_entry(command, &mut rt_attrs) {
        return json!({ "ok": false, "error": e.to_string(), "command": command });
    }
    // Snapshot the event log so everything after is this command's cascade.
    let pre_count = rt.event_bus.events().len();
    let result = match rt.dispatch_deferred(command, rt_attrs) {
        Ok(r) => r,
        Err(e) => return json!({ "ok": false, "error": e.to_string() }),
    };
    // Settle the cascade + the primary-adapter synchronous wait, then detach the
    // out-of-process adapter handlers — the exact sequence the cold CLI ran.
    rt.pump_outbox();
    rt.pump();
    rt.drain_outbound_to_quiescence();
    rt.pump_outbound_events();
    rt.policy_engine.reset_in_flight();

    let cascade: Vec<serde_json::Value> = rt.event_bus.events()[pre_count..].iter().map(|e| {
        let mut o = serde_json::Map::new();
        o.insert("event".to_string(), json!(e.name));
        o.insert("aggregate_type".to_string(), json!(e.aggregate_type));
        o.insert("aggregate_id".to_string(), json!(e.aggregate_id));
        if let Some(id) = &e.event_id { o.insert("event_id".to_string(), json!(id)); }
        if let Some(cid) = &e.causation_id { o.insert("causation_id".to_string(), json!(cid)); }
        serde_json::Value::Object(o)
    }).collect();

    let state = state_of(rt, &result.aggregate_type, &result.aggregate_id);
    let mut out = serde_json::Map::new();
    out.insert("ok".to_string(), json!(true));
    out.insert("aggregate_type".to_string(), json!(result.aggregate_type));
    out.insert("aggregate_id".to_string(), json!(result.aggregate_id));
    if let Some(ev) = &result.event {
        out.insert("event".to_string(), json!(ev.name));
    }
    out.insert("cascade".to_string(), json!(cascade));
    out.insert("state".to_string(), state);
    serde_json::Value::Object(out)
}

/// Stamp + authorize + resolve a read-only query against an already-booted
/// runtime. Resolves the verb as an FQN (`Realm[::Context]::Bluebook::Aggregate
/// .snake_query`) first, then as a bare query name — the same two arms the cold
/// CLI read door used. Returns the query's own JSON result
/// (`{ aggregate, query, state }`) on admit, `{ ok: false, error, command }` on
/// a governance denial, or `{ ok: false, error }` for an unknown verb.
pub fn gated_query(
    rt: &mut Runtime,
    verb: &str,
    params: HashMap<String, String>,
    principal: Principal,
) -> serde_json::Value {
    // FQN arm — Realm[::Context…]::Bluebook::Aggregate.snake_query. Enforce the
    // realm + context against each aggregate's stamped path, the SAME check the
    // command resolver applies, so queries and commands disambiguate identically.
    if let Some((head, tail)) = verb.rsplit_once('.') {
        let segments: Vec<&str> = head.split("::").collect();
        if segments.len() >= 2 {
            let agg = segments[segments.len() - 1];
            let (q_realm, q_context) = crate::heki::fqn_realm_context(verb);
            let matched = rt.domain.aggregates.iter()
                .filter(|a| a.name == agg
                    && crate::heki::realm_context_matches(
                        a.realm_path.as_deref(), q_realm.as_deref(), q_context.as_deref()))
                .find_map(|a| a.queries.iter()
                    .find(|q| crate::util::snake_case(&q.name) == tail || q.name == tail)
                    .map(|q| (a.context.clone(), a.name.clone(), q.name.clone())));
            if let Some((ctx, agg_name, q_name)) = matched {
                let mut gate: HashMap<String, Value> = HashMap::new();
                stamp_principal(&mut gate, &principal);
                if let Err(e) = rt.authorize_entry(verb, &mut gate) {
                    return json!({ "ok": false, "error": e.to_string(), "command": verb });
                }
                return rt.resolve_query_qualified(ctx.as_deref(), &agg_name, &q_name, &params);
            }
        }
    }
    // Bare arm — an unqualified query name (the internal `dispatch_hecksagon`
    // callers still pass bare `ListAll` / `MatchInput`).
    let is_query = rt.domain.aggregates.iter()
        .any(|a| a.queries.iter().any(|q| q.name == verb));
    if is_query {
        let mut gate: HashMap<String, Value> = HashMap::new();
        stamp_principal(&mut gate, &principal);
        if let Err(e) = rt.authorize_entry(verb, &mut gate) {
            return json!({ "ok": false, "error": e.to_string(), "command": verb });
        }
        return rt.resolve_query(verb, &params);
    }
    json!({ "ok": false, "error": format!("unknown query: {}", verb) })
}

// ============================================================
// One-shot FFI entries — boot + core, panic-safe
// ============================================================

/// Drive one command against `root` in-process. Boots a persistence-backed
/// runtime, stamps `principal`, runs the governed gate, dispatches, settles the
/// cascade, and returns the verdict JSON. NEVER panics across the boundary — a
/// load/parse/dispatch panic is caught and returned as `{ ok: false, error }`,
/// so an FFI binding (magnus / cbindgen) can't unwind into its host.
pub fn dispatch_once(
    root: &str,
    command: &str,
    attrs: HashMap<String, String>,
    principal: Principal,
) -> serde_json::Value {
    catch_unwind(AssertUnwindSafe(|| {
        let mut rt = boot_for_dispatch(root);
        authorized_dispatch(&mut rt, command, attrs, principal)
    }))
    .unwrap_or_else(|_| json!({ "ok": false, "error": format!("embed: panicked dispatching '{}'", command) }))
}

/// Resolve one read-only query against `root` in-process. Same boot + gate as
/// [`dispatch_once`], panic-safe, returning the query's JSON result or a
/// governance-denial / unknown-verb `{ ok: false, ... }` shape.
pub fn query_once(
    root: &str,
    query: &str,
    params: HashMap<String, String>,
    principal: Principal,
) -> serde_json::Value {
    catch_unwind(AssertUnwindSafe(|| {
        let mut rt = boot_for_dispatch(root);
        gated_query(&mut rt, query, params, principal)
    }))
    .unwrap_or_else(|_| json!({ "ok": false, "error": format!("embed: panicked querying '{}'", query) }))
}
