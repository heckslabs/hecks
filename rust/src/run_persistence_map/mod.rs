//! `storehouse persistence-map` — the i728 Phase-B persistence projection.
//!
//! A READ-ONLY view, derived from the loaded IR, of which backend every
//! aggregate's persistence port resolves to and WHY. The hecksagons are the
//! sole source of truth ; this map is computed from them, never stored — so it
//! cannot drift. It is the migration worklist in motion : every
//! `unwired → default` row is a TODO, and a live store under `information/` is
//! positive evidence the row needs an explicit `:heki` (durable-by-default).
//!
//!   storehouse persistence-map <agg-dir> [--json]
//!
//! Source resolution mirrors the runtime's own rule EXACTLY (a hecksagon whose
//! `name == aggregate.context` governs that context's persistence — the same
//! match `apply_sqlite_persistence` and `unwired_aggregates` use), so the
//! projection is consistent-by-construction with what actually persists.
//!
//! G3 (the open hole the verifier exists to kill) : process-manager instance
//! stores and any other writer that is NOT an aggregate would be invisible to
//! an aggregate-only walk. So the map ALSO surfaces ORPHAN stores — live
//! `*.heki` under `information/` that no aggregate row claims — making the honest
//! assertion "everything that writes to information/ is accounted for", not
//! merely "every aggregate is".

mod render;
pub use render::{render_json, render_table};

use crate::hecksagon_ir::Hecksagon;
use crate::ir::Domain;
use std::collections::{BTreeSet, HashMap};
use std::path::Path;

/// One aggregate's persistence resolution.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    /// `context::aggregate` (the runtime repo_key).
    pub fqn: String,
    /// The adapter the governing hecksagon declares, e.g. `heki` / `memory` /
    /// `sqlite`. `None` when no hecksagon names this context with an adapter.
    pub declared: Option<String>,
    /// The honest reason — `declared :heki` / `declared :memory` /
    /// `unwired → default`. This IS the worklist label.
    pub source: String,
    /// True when a live `.heki` store exists for this aggregate under the
    /// info dir — positive evidence for a durable (`:heki`) classification.
    pub live_store: bool,
}

/// Build the per-aggregate rows from the loaded domain + hecksagons.
/// Deterministic (sorted by fqn) so the rendered map and any diff are stable.
pub fn build_rows(domain: &Domain, hecksagons: &[Hecksagon], info_dir: &str) -> Vec<Row> {
    // context name → the SET of distinct adapters declared for it. Persistence
    // is per-CONTEXT, keyed by hecksagon name (mirrors `unwired_aggregates` /
    // `apply_sqlite_persistence`). A set, not a single value, because the
    // load-set spans repo-root buckets + sibling repos where the SAME context
    // name is declared more than once (Inbox in conception=:heki AND in
    // tools/=:memory). Collapsing that to last-wins would let the map lie ; a
    // divergent set is surfaced as a CONFLICT row instead of a silent pick.
    let mut wired: HashMap<&str, BTreeSet<&str>> = HashMap::new();
    for h in hecksagons {
        if let Some(p) = h.persistence.as_deref() {
            wired.entry(h.name.as_str()).or_default().insert(p);
        }
    }

    let mut rows: Vec<Row> = domain
        .aggregates
        .iter()
        .map(|agg| {
            let ctx = agg.context.as_deref();
            let (declared, source) = match ctx.and_then(|c| wired.get(c)) {
                None => (None, "unwired → default".to_string()),
                Some(set) if set.len() == 1 => {
                    let a = *set.iter().next().unwrap();
                    (Some(a.to_string()), format!("declared :{a}"))
                }
                Some(set) => {
                    let list: Vec<String> = set.iter().map(|a| format!(":{a}")).collect();
                    (Some(list.join("|")), format!("CONFLICT {}", list.join(" vs ")))
                }
            };
            Row {
                fqn: crate::runtime::repo_key(ctx, &agg.name),
                declared,
                source,
                live_store: store_exists(info_dir, &agg.name),
            }
        })
        .collect();
    rows.sort_by(|a, b| a.fqn.cmp(&b.fqn));
    rows.dedup();
    rows
}

/// Live `.heki` stores under `info_dir` that NO aggregate row claims — the G3
/// universe (process-manager instances + any non-aggregate writer). Returned
/// sorted ; process-manager stores are prefixed `process_managers/` so they
/// read as the distinct class they are.
pub fn find_orphans(domain: &Domain, info_dir: &str) -> Vec<String> {
    let claimed: BTreeSet<String> = domain
        .aggregates
        .iter()
        .map(|agg| crate::util::snake_case(&agg.name))
        .collect();
    // Compare through snake_case on BOTH sides : on a case-insensitive FS a
    // legacy CamelCase store dir (`Attention/`) holds the SAME store the
    // snake-cased aggregate (`attention`) writes to, so the raw on-disk name
    // must be normalised before the diff or it reads as a false orphan. The
    // displayed name stays the raw on-disk one so the file is findable.
    let mut orphans: Vec<String> = live_store_stems(info_dir)
        .into_iter()
        .filter(|(stem, _)| !claimed.contains(&crate::util::snake_case(stem)))
        .map(|(stem, pm)| if pm { format!("process_managers/{stem}") } else { stem })
        .collect();
    orphans.sort();
    orphans
}

/// True when `<info_dir>/<snake>.heki` OR `<info_dir>/<snake>/<snake>.heki`
/// exists — the two store layouts the runtime uses (top-level file vs
/// per-aggregate directory).
fn store_exists(info_dir: &str, agg_name: &str) -> bool {
    let snake = crate::util::snake_case(agg_name);
    let base = Path::new(info_dir);
    base.join(format!("{snake}.heki")).is_file()
        || base.join(&snake).join(format!("{snake}.heki")).is_file()
}

/// Every live store stem under `info_dir`, as `(stem, is_process_manager)`.
/// Top-level `<stem>.heki`, per-aggregate `<stem>/<stem>.heki`, and
/// `process_managers/<stem>.heki`. Snapshot dirs and dotfiles are skipped.
fn live_store_stems(info_dir: &str) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    let base = Path::new(info_dir);
    let Ok(entries) = std::fs::read_dir(base) else {
        return out;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        let Some(name) = p.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        if p.is_file() {
            if let Some(stem) = name.strip_suffix(".heki") {
                out.push((stem.to_string(), false));
            }
        } else if p.is_dir() {
            if name == "process_managers" {
                if let Ok(pms) = std::fs::read_dir(&p) {
                    for pm in pms.flatten() {
                        let pn = pm.file_name();
                        if let Some(stem) = pn.to_str().and_then(|s| s.strip_suffix(".heki")) {
                            if !stem.starts_with('.') {
                                out.push((stem.to_string(), true));
                            }
                        }
                    }
                }
            } else if base.join(name).join(format!("{name}.heki")).is_file() {
                out.push((name.to_string(), false));
            }
        }
    }
    out
}

/// Entry-point — invoked from `main.rs` when `command == "persistence-map"`.
/// Returns the process exit code.
pub fn run(domain: &Domain, hecksagons: &[Hecksagon], info_dir: &str, json: bool) -> i32 {
    let rows = build_rows(domain, hecksagons, info_dir);
    let orphans = find_orphans(domain, info_dir);
    if json {
        println!("{}", render_json(&rows, &orphans));
    } else {
        print!("{}", render_table(&rows, &orphans, info_dir));
    }
    0
}
