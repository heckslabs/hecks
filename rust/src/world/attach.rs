//! World-server boot attachment + dump projection (i610) — carved out of
//! main.rs into the `world` GROW concern. `attach_world_servers` walks the
//! project tree for `*.world` files, parses each, and unions every declared
//! MCP server onto the runtime so `resolve_world_server` can look one up at
//! dispatch. `dump_servers_json` is the `dump-world` projection of those
//! servers, kept next to the attach walk it mirrors.
//!
//! [antibody-exempt: rust/src/world/attach.rs — kernel-floor world boot.
//!  The world-walk that unions `*.world` MCP servers onto the runtime is
//!  the boot side of the i610 world-grammar block ; it is host-only fs
//!  plumbing the .world grammar declares, not bluebookable domain logic.]

use crate::runtime::Runtime;
use crate::world::ir::World;
use std::fs;

/// i610 — walk `agg_dir` for `*.world` files and union every declared MCP
/// server onto the runtime. Deterministic (paths sorted) ; the first world
/// file that declares servers wins the `world_servers_path` log anchor.
pub fn attach_world_servers(rt: &mut Runtime, agg_dir: &str) {
    let root = std::path::Path::new(agg_dir);
    let mut stack = vec![root.to_path_buf()];
    let mut worlds: Vec<std::path::PathBuf> = vec![];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().map(|e| e == "world").unwrap_or(false) {
                worlds.push(p);
            }
        }
    }
    worlds.sort();
    for wp in &worlds {
        let Ok(src) = fs::read_to_string(wp) else { continue };
        let world = crate::world::parser::parse(&src);
        if world.servers.is_empty() { continue; }
        if rt.world_servers_path.is_none() {
            rt.world_servers_path = Some(wp.to_string_lossy().to_string());
        }
        rt.world_servers.extend(world.servers);
    }
}

/// Sprint 14 world-wires-real-adapters — walk `agg_dir` for `*.world`
/// files and union every top-level `adapter "Name" do; ... end` binding
/// onto the runtime. Sibling of `attach_world_servers` ; presence of
/// a binding here IS the signal that switches a driven adapter from
/// canned (memory by default) to real (config from the binding). No
/// `backend:` flag : the binding's values themselves carry the
/// per-deployment config (URL, env-var, output overrides, etc.).
pub fn attach_world_adapter_bindings(rt: &mut Runtime, agg_dir: &str) {
    let root = std::path::Path::new(agg_dir);
    let mut stack = vec![root.to_path_buf()];
    let mut worlds: Vec<std::path::PathBuf> = vec![];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().map(|e| e == "world").unwrap_or(false) {
                worlds.push(p);
            }
        }
    }
    worlds.sort();
    for wp in &worlds {
        let Ok(src) = fs::read_to_string(wp) else { continue };
        let world = crate::world::parser::parse(&src);
        if world.adapter_bindings.is_empty() { continue; }
        rt.world_adapter_bindings.extend(world.adapter_bindings);
    }
}

/// Walk `agg_dir` (and its `aggregates/` subdirectory when present) for
/// `*.world` files that declare `heki do dir "…" end`. Returns a map of
/// `category → canonical_heki_dir` resolved relative to each world file's
/// directory. Category key = `world.name.to_lowercase()` (e.g. `"Plan"` →
/// `"plan"`), matching the `category "plan"` stamp the parser writes on
/// aggregates declared in that domain.
///
/// Used by `apply_per_domain_world_dirs` to wire per-category repositories
/// to their correct on-disk `.heki` stores when booting from a conception
/// root (e.g. `"."` or `/…/hecks_conception`) rather than from the
/// `aggregates/` subdirectory directly.
pub fn collect_world_heki_dirs(agg_dir: &str) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    let base = std::path::Path::new(agg_dir);
    // Search both agg_dir and agg_dir/aggregates/ so the function works
    // whether agg_dir is the conception root or the aggregates/ subdir.
    let mut roots = vec![base.to_path_buf()];
    let sub = base.join("aggregates");
    if sub.is_dir() { roots.push(sub); }
    for root in &roots {
        let Ok(entries) = std::fs::read_dir(root) else { continue };
        for entry in entries.flatten() {
            let p = entry.path();
            if p.extension().map_or(true, |e| e != "world") { continue; }
            let Ok(source) = fs::read_to_string(&p) else { continue };
            let world = crate::world::parser::parse(&source);
            let cat = world.name.to_lowercase();
            if cat.is_empty() { continue; }
            let Some(dir_value) = world.config_for("heki").and_then(|c| c.get("dir")) else {
                continue;
            };
            let world_dir = p.parent().unwrap_or(root.as_path());
            let resolved = world_dir.join(dir_value);
            if resolved.exists() {
                map.insert(cat, resolved.to_string_lossy().into_owned());
            }
        }
    }
    map
}

/// Patch repositories whose aggregate has a per-domain `.world`-declared
/// heki dir. Must be called after `Runtime::boot_with_hecksagons` while
/// all `LazyRepository` entries are still uninitialised (no disk read yet)
/// so they can be safely replaced with correctly-rooted counterparts.
///
/// Without this, a dispatch rooted at the conception dir falls back to
/// `miette-state/information/` for all domains, losing writes that should
/// land in domain-specific stores like `aggregates/plan/.heki/`.
pub fn apply_per_domain_world_dirs(rt: &mut Runtime, agg_dir: &str) {
    let world_dirs = collect_world_heki_dirs(agg_dir);
    if world_dirs.is_empty() { return; }
    let patches: Vec<(String, String, Option<String>, Option<String>)> =
        rt.domain.aggregates.iter().filter_map(|agg| {
            let cat = agg.category.as_deref()?;
            let heki_dir = world_dirs.get(cat)?;
            let key = crate::runtime::repo_key(agg.context.as_deref(), &agg.name);
            Some((key, heki_dir.clone(), agg.identified_by.clone(), agg.context.clone()))
        }).collect();
    for (key, heki_dir, identified_by, context) in patches {
        // Derive the bare aggregate name from the repo key (strips context:: prefix).
        let agg_name = if let Some(pos) = key.find("::") {
            key[pos + 2..].to_string()
        } else {
            key.clone()
        };
        rt.repositories.insert(
            key,
            crate::runtime::LazyRepository::new(
                &agg_name,
                Some(heki_dir),
                identified_by,
                context,
            ),
        );
    }
}

/// i610 — `dump-world` projection of a world's MCP server declarations.
pub fn dump_servers_json(world: &World) -> Vec<serde_json::Value> {
    world.servers.iter().map(|s| {
        serde_json::json!({
            "name": s.name,
            "token_env": s.token_env,
        })
    }).collect()
}
