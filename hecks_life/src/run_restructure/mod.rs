//! Restructure capability runner — applies a target file Layout to
//! the conception, with full event-sourced rewind via the Move
//! aggregate's lifecycle.
//!
//! Sibling bluebook : `capabilities/restructure/restructure.bluebook`
//! declares Layout / Placement / Move / Convention aggregates with
//! commands :
//!
//!   Layout.Define / Plan / Apply / RevertTo
//!   Placement.Add
//!   Move.PlanMove / ApplyMove / VerifyMove / FailMove / RevertMove
//!   Convention.Declare
//!
//! Sibling hecksagon : `capabilities/restructure/restructure.hecksagon`
//! declares :fs + :memory + :stdout adapters.
//!
//! Fires when the bluebook declares aggregate `Layout` with command
//! `Apply` AND aggregate `Move` AND the hecksagon declares :fs +
//! :memory + :stdout. When detected, [`run`] takes over from the
//! generic dispatcher and walks the entrypoint's phase :
//!
//!   - `Layout.Apply <name>`     → iterate planned Moves, dispatch
//!                                  ApplyMove for each, observe the
//!                                  VerifyOnApplied policy chain.
//!   - `Layout.Plan <name>`      → walk filesystem against the
//!                                  layout's Placements ; dispatch
//!                                  PlanMove per matched file.
//!   - `Layout.RevertTo <name>`  → read Move records in reverse-
//!                                  applied order ; dispatch
//!                                  RevertMove until layout state
//!                                  matches target.
//!
//! ## Retirement contract — i147 sibling
//!
//! This runner is hand-written today because `capability_runner_shape`
//! has the body_kind catalog (post-`59634914` walk_filesystem add)
//! but its specializer hasn't shipped. Once the catalog gets a Phase
//! row processor + emitter templates, this file regenerates from
//! Phase rows declared on Restructure. The hand-written shape here
//! is **the explicit blueprint** for what the meta-shape's specializer
//! must produce ; byte-identity becomes enforceable the moment the
//! emitter lands.
//!
//! [antibody-exempt: hecks_life/src/run_restructure/mod.rs —
//!  hand-written MVP runner for the Restructure capability ; retires
//!  under capability_runner_shape's specializer (i147 sibling). The
//!  three phases (plan/apply/revert) are the blueprint for what
//!  walk_filesystem + dispatch_command body_kind emitters must
//!  produce. Net : one new entry in run.rs detection chain.]

use crate::run::ExitKind;
use crate::runtime::adapter_registry::AdapterRegistry;
use crate::runtime::{Runtime, Value};

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// True when the bluebook + hecksagon shape wants the restructure runner.
pub fn is_restructure_capability(registry: &AdapterRegistry, rt: &Runtime) -> bool {
    if registry.io("fs").is_none() { return false; }
    if registry.io("stdout").is_none() { return false; }
    let names: Vec<&str> = rt.domain.aggregates.iter()
        .map(|a| a.name.as_str()).collect();
    let has_layout = names.iter().any(|n| *n == "Layout");
    let has_move   = names.iter().any(|n| *n == "Move");
    let has_apply  = rt.domain.aggregates.iter()
        .filter(|a| a.name == "Layout")
        .any(|a| a.commands.iter().any(|c| c.name == "Apply"));
    has_layout && has_move && has_apply
}

/// Run the restructure pipeline for the dispatched entrypoint.
/// Recognises Layout.Apply / Plan / RevertTo as the phase selectors ;
/// any other entrypoint falls through to the generic dispatcher.
pub fn run(
    rt: &mut Runtime,
    registry: &AdapterRegistry,
    entrypoint: &str,
    script_path: &str,
    argv_extra: &[String],
) -> i32 {
    let attrs = parse_attrs(argv_extra);
    let conception = conception_dir(script_path);
    let fs_root = fs_root(registry).unwrap_or_else(|| conception.clone());

    match entrypoint {
        "Layout.Plan" => phase_plan(rt, &fs_root, &attrs),
        "Layout.Apply" => phase_apply(rt, &fs_root, &attrs),
        "Layout.RevertTo" => phase_revert(rt, &fs_root, &attrs),
        _ => match rt.dispatch(entrypoint, attrs) {
            Ok(_) => ExitKind::Ok.code(),
            Err(e) => { eprintln!("hecks-life restructure: {}", e); ExitKind::AdapterFailure.code() }
        }
    }
}

/// Phase : Layout.Plan — walk the filesystem under fs_root against the
/// named layout's Placement rules ; dispatch PlanMove for each match.
/// The :fs walk is a stand-in for the eventual walk_filesystem body_kind
/// emitter ; same logic, just hand-written for now.
fn phase_plan(rt: &mut Runtime, fs_root: &Path, attrs: &HashMap<String, Value>) -> i32 {
    let layout_name = match attrs.get("name") {
        Some(Value::Str(s)) => s.clone(),
        _ => { eprintln!("Layout.Plan : missing name="); return ExitKind::AdapterFailure.code(); }
    };
    let placements = collect_placements(rt, &layout_name);
    if placements.is_empty() {
        eprintln!("Layout.Plan : no placements attached to layout '{}'", layout_name);
        return ExitKind::AdapterFailure.code();
    }
    let mut entries: Vec<PathBuf> = Vec::new();
    walk_filesystem(fs_root, &mut entries);
    let mut planned: usize = 0;
    for path in &entries {
        for (pattern, destination) in &placements {
            if matches_pattern(path, pattern) {
                let from = path.to_string_lossy().into_owned();
                let to = destination_for(path, fs_root, destination);
                if from == to { continue; }
                let move_id = format!("m{}", planned + 1);
                let mut move_attrs: HashMap<String, Value> = HashMap::new();
                move_attrs.insert("move_id".into(), Value::Str(move_id.clone()));
                move_attrs.insert("from".into(),    Value::Str(from));
                move_attrs.insert("to".into(),      Value::Str(to));
                let _ = rt.dispatch("PlanMove", move_attrs);
                planned += 1;
                break;
            }
        }
    }
    let mut layout_attrs: HashMap<String, Value> = HashMap::new();
    layout_attrs.insert("name".into(), Value::Str(layout_name.clone()));
    let _ = rt.dispatch("Plan", layout_attrs);
    println!("Layout.Plan '{}' — {} moves queued ({} files scanned)", layout_name, planned, entries.len());
    ExitKind::Ok.code()
}

/// Phase : Layout.Apply — iterate planned Move records ; dispatch
/// ApplyMove for each ; the :fs adapter executes the rename ; the
/// VerifyOnApplied policy chain auto-fires VerifyMove. Errors are
/// logged but do not abort the chain (idempotent retry).
fn phase_apply(rt: &mut Runtime, fs_root: &Path, attrs: &HashMap<String, Value>) -> i32 {
    let layout_name = match attrs.get("name") {
        Some(Value::Str(s)) => s.clone(),
        _ => { eprintln!("Layout.Apply : missing name="); return ExitKind::AdapterFailure.code(); }
    };
    let planned_moves = collect_planned_moves(rt);
    let now = current_iso8601();
    let mut applied: usize = 0;
    let mut failed: usize = 0;
    for (move_id, from, to) in &planned_moves {
        match execute_move(fs_root, from, to) {
            Ok(()) => {
                let mut a: HashMap<String, Value> = HashMap::new();
                a.insert("move_id".into(),    Value::Str(move_id.clone()));
                a.insert("applied_at".into(), Value::Str(now.clone()));
                let _ = rt.dispatch("ApplyMove", a);
                applied += 1;
            }
            Err(e) => {
                eprintln!("Layout.Apply : {} → {} failed : {}", from, to, e);
                failed += 1;
            }
        }
    }
    let mut layout_attrs: HashMap<String, Value> = HashMap::new();
    layout_attrs.insert("name".into(), Value::Str(layout_name.clone()));
    let _ = rt.dispatch("Apply", layout_attrs);
    println!("Layout.Apply '{}' — {} applied, {} failed", layout_name, applied, failed);
    if failed > 0 { ExitKind::AdapterFailure.code() } else { ExitKind::Ok.code() }
}

/// Phase : Layout.RevertTo — walk applied Move records in reverse and
/// dispatch RevertMove on each. The MoveReverted event payload swaps
/// from + to so the event log read in reverse IS filesystem undo.
fn phase_revert(rt: &mut Runtime, fs_root: &Path, attrs: &HashMap<String, Value>) -> i32 {
    let layout_name = match attrs.get("name") {
        Some(Value::Str(s)) => s.clone(),
        _ => { eprintln!("Layout.RevertTo : missing name="); return ExitKind::AdapterFailure.code(); }
    };
    let mut applied_moves = collect_applied_moves(rt);
    applied_moves.reverse();
    let mut reverted: usize = 0;
    for (move_id, from, to) in &applied_moves {
        match execute_move(fs_root, to, from) {
            Ok(()) => {
                let mut a: HashMap<String, Value> = HashMap::new();
                a.insert("move_id".into(), Value::Str(move_id.clone()));
                let _ = rt.dispatch("RevertMove", a);
                reverted += 1;
            }
            Err(e) => eprintln!("Layout.RevertTo : revert {} → {} failed : {}", to, from, e),
        }
    }
    let mut layout_attrs: HashMap<String, Value> = HashMap::new();
    layout_attrs.insert("name".into(), Value::Str(layout_name.clone()));
    let _ = rt.dispatch("RevertTo", layout_attrs);
    println!("Layout.RevertTo '{}' — {} moves reverted", layout_name, reverted);
    ExitKind::Ok.code()
}

// ---- helpers ---------------------------------------------------------

fn parse_attrs(argv_extra: &[String]) -> HashMap<String, Value> {
    let mut out = HashMap::new();
    for a in argv_extra {
        if let Some((k, v)) = a.split_once('=') {
            out.insert(k.to_string(), Value::Str(v.to_string()));
        }
    }
    out
}

fn collect_placements(rt: &Runtime, _layout_name: &str) -> Vec<(String, String)> {
    let key = crate::runtime::repo_key(None, "Placement");
    match rt.repositories.get(&key) {
        Some(repo) => repo.all().iter().map(|s| {
            let pattern = s.fields.get("pattern").map(value_to_string).unwrap_or_default();
            let destination = s.fields.get("destination").map(value_to_string).unwrap_or_default();
            (pattern, destination)
        }).collect(),
        None => Vec::new(),
    }
}

fn collect_planned_moves(rt: &Runtime) -> Vec<(String, String, String)> {
    let key = crate::runtime::repo_key(None, "Move");
    match rt.repositories.get(&key) {
        Some(repo) => repo.all().iter()
            .filter(|s| s.fields.get("status").map(value_to_string).as_deref() == Some("planned"))
            .map(|s| (
                s.fields.get("move_id").map(value_to_string).unwrap_or(s.id.clone()),
                s.fields.get("from").map(value_to_string).unwrap_or_default(),
                s.fields.get("to").map(value_to_string).unwrap_or_default(),
            ))
            .collect(),
        None => Vec::new(),
    }
}

fn collect_applied_moves(rt: &Runtime) -> Vec<(String, String, String)> {
    let key = crate::runtime::repo_key(None, "Move");
    match rt.repositories.get(&key) {
        Some(repo) => repo.all().iter()
            .filter(|s| s.fields.get("status").map(value_to_string).as_deref() == Some("applied"))
            .map(|s| (
                s.fields.get("move_id").map(value_to_string).unwrap_or(s.id.clone()),
                s.fields.get("from").map(value_to_string).unwrap_or_default(),
                s.fields.get("to").map(value_to_string).unwrap_or_default(),
            ))
            .collect(),
        None => Vec::new(),
    }
}

fn value_to_string(v: &Value) -> String {
    match v {
        Value::Str(s) => s.clone(),
        Value::Int(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

fn walk_filesystem(dir: &Path, out: &mut Vec<PathBuf>) {
    if !dir.is_dir() { return; }
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let p = entry.path();
        let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if matches!(name, ".git" | "target" | "information" | ".claude" | "node_modules") {
            continue;
        }
        if p.is_dir() { walk_filesystem(&p, out); }
        else { out.push(p); }
    }
}

fn matches_pattern(path: &Path, pattern: &str) -> bool {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    if let Some(suffix) = pattern.strip_prefix("*.") {
        return name.ends_with(&format!(".{}", suffix));
    }
    name == pattern
}

fn destination_for(path: &Path, fs_root: &Path, destination: &str) -> String {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let dest_dir = fs_root.join(destination.trim_end_matches('/'));
    dest_dir.join(name).to_string_lossy().into_owned()
}

fn execute_move(_fs_root: &Path, from: &str, to: &str) -> std::io::Result<()> {
    if let Some(parent) = std::path::Path::new(to).parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::rename(from, to)
}

fn current_iso8601() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    format!("{}", now)
}

fn conception_dir(script_path: &str) -> PathBuf {
    let abs = std::fs::canonicalize(script_path)
        .unwrap_or_else(|_| PathBuf::from(script_path));
    let mut cur = abs.parent().unwrap_or_else(|| Path::new(".")).to_path_buf();
    for _ in 0..6 {
        if cur.join("information").is_dir() && cur.join("capabilities").is_dir() {
            return cur;
        }
        if !cur.pop() { break; }
    }
    abs.parent().unwrap_or_else(|| Path::new(".")).to_path_buf()
}

fn fs_root(registry: &AdapterRegistry) -> Option<PathBuf> {
    let fs = registry.io("fs")?;
    let (_, root) = fs.options.iter().find(|(k, _)| k == "root")?;
    Some(PathBuf::from(root.trim_matches('"')))
}
