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

/// i610 — `dump-world` projection of a world's MCP server declarations.
pub fn dump_servers_json(world: &World) -> Vec<serde_json::Value> {
    world.servers.iter().map(|s| {
        serde_json::json!({
            "name": s.name,
            "token_env": s.token_env,
        })
    }).collect()
}
