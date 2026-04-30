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
    // fs_root precedence : explicit `root=<path>` argv override (used
    // by integration tests + ad-hoc runs) → :fs adapter's declared
    // root (when absolute) → conception_dir fallback. The override
    // exists because `adapter :fs, root: "."` resolves relatively and
    // the runner needs an absolute anchor for tree walks.
    let fs_root = argv_extra.iter()
        .find_map(|a| a.strip_prefix("root=").map(PathBuf::from))
        .or_else(|| fs_root_from_registry(registry).filter(|p| p.is_absolute()))
        .unwrap_or_else(|| conception.clone());

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
                let move_id = format!("{}-m{}", layout_name, planned + 1);
                let mut move_attrs: HashMap<String, Value> = HashMap::new();
                move_attrs.insert("move_id".into(), Value::Str(move_id.clone()));
                move_attrs.insert("from".into(),    Value::Str(from));
                move_attrs.insert("to".into(),      Value::Str(to));
                move_attrs.insert("layout".into(),  Value::Str(layout_name.clone()));
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

/// Phase : Layout.Apply — iterate planned Move records linked to this
/// layout ; for each, execute the :fs rename, dispatch ApplyMove (the
/// VerifyOnApplied policy auto-fires VerifyMove on success), then run
/// validator on the moved file ; on validator failure dispatch FailMove
/// (the RevertOnFail policy auto-fires RevertMove). Per-move errors
/// are logged but do not abort the chain — partial-failure semantics
/// per Tier 3 are deferred.
fn phase_apply(rt: &mut Runtime, fs_root: &Path, attrs: &HashMap<String, Value>) -> i32 {
    let layout_name = match attrs.get("name") {
        Some(Value::Str(s)) => s.clone(),
        _ => { eprintln!("Layout.Apply : missing name="); return ExitKind::AdapterFailure.code(); }
    };
    let planned_moves = collect_planned_moves(rt, &layout_name);
    let now = current_iso8601();
    let mut applied: usize = 0;
    let mut failed: usize = 0;
    let mut rolled_back: usize = 0;
    for (move_id, from, to) in &planned_moves {
        match execute_move(fs_root, from, to) {
            Ok(()) => {
                let mut a: HashMap<String, Value> = HashMap::new();
                // Self-ref commands need the lowercase aggregate name as
                // the id attribute (`move` for the Move aggregate). The
                // identified_by field (`move_id`) is also passed for
                // completeness in case downstream policies read it.
                a.insert("move".into(),       Value::Str(move_id.clone()));
                a.insert("move_id".into(),    Value::Str(move_id.clone()));
                a.insert("applied_at".into(), Value::Str(now.clone()));
                if let Err(e) = rt.dispatch("ApplyMove", a) {
                    eprintln!("Layout.Apply : ApplyMove dispatch failed for {} : {}", move_id, e);
                    failed += 1;
                    continue;
                }
                applied += 1;
                // Real post-move validation : parse the moved file if
                // it's a bluebook ; on failure dispatch FailMove which
                // RevertOnFail auto-rolls back via RevertMove.
                if to.ends_with(".bluebook") && !validate_bluebook(to) {
                    let mut fa: HashMap<String, Value> = HashMap::new();
                    fa.insert("move".into(),    Value::Str(move_id.clone()));
                    fa.insert("move_id".into(), Value::Str(move_id.clone()));
                    let _ = rt.dispatch("FailMove", fa);
                    // Inverse rename so :fs reflects the rolled-back state.
                    let _ = execute_move(fs_root, to, from);
                    rolled_back += 1;
                }
            }
            Err(e) => {
                eprintln!("Layout.Apply : {} → {} failed at :fs rename : {}", from, to, e);
                failed += 1;
            }
        }
    }
    let mut layout_attrs: HashMap<String, Value> = HashMap::new();
    layout_attrs.insert("name".into(), Value::Str(layout_name.clone()));
    let _ = rt.dispatch("Apply", layout_attrs);
    println!(
        "Layout.Apply '{}' — {} applied, {} validator-rolled-back, {} :fs-failed",
        layout_name, applied, rolled_back, failed
    );
    if failed > 0 { ExitKind::AdapterFailure.code() } else { ExitKind::Ok.code() }
}

/// Phase : Layout.RevertTo — walk applied Move records linked to the
/// named layout in reverse-applied order, dispatch RevertMove on each.
/// The MoveReverted event payload swaps from + to so the event log
/// read in reverse IS filesystem undo. Layout-Move linkage scopes
/// the revert so multi-layout event histories don't conflate moves.
fn phase_revert(rt: &mut Runtime, fs_root: &Path, attrs: &HashMap<String, Value>) -> i32 {
    let layout_name = match attrs.get("name") {
        Some(Value::Str(s)) => s.clone(),
        _ => { eprintln!("Layout.RevertTo : missing name="); return ExitKind::AdapterFailure.code(); }
    };
    let mut applied_moves = collect_applied_moves(rt, &layout_name);
    applied_moves.reverse();
    let mut reverted: usize = 0;
    for (move_id, from, to) in &applied_moves {
        match execute_move(fs_root, to, from) {
            Ok(()) => {
                let mut a: HashMap<String, Value> = HashMap::new();
                a.insert("move".into(),    Value::Str(move_id.clone()));
                a.insert("move_id".into(), Value::Str(move_id.clone()));
                if let Err(e) = rt.dispatch("RevertMove", a) {
                    eprintln!("Layout.RevertTo : RevertMove dispatch failed for {} : {}", move_id, e);
                    continue;
                }
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
    let Some(key) = crate::runtime::repo_lookup_key(&rt.repositories, "Placement") else {
        return Vec::new();
    };
    match rt.repositories.get(&key) {
        Some(repo) => repo.all().iter().map(|s| {
            let pattern = s.fields.get("pattern").map(value_to_string).unwrap_or_default();
            let destination = s.fields.get("destination").map(value_to_string).unwrap_or_default();
            (pattern, destination)
        }).collect(),
        None => Vec::new(),
    }
}

fn collect_planned_moves(rt: &Runtime, layout_name: &str) -> Vec<(String, String, String)> {
    collect_moves_for(rt, "planned", layout_name)
}

/// Revertable moves : applied OR verified (both successfully relocated
/// the file). Status='failed' is filtered out — those are already
/// rolled back by the RevertOnFail policy chain. Status='reverted'
/// is filtered out — already undone. Status='planned' is filtered
/// out — never executed, nothing to revert.
fn collect_applied_moves(rt: &Runtime, layout_name: &str) -> Vec<(String, String, String)> {
    let Some(key) = crate::runtime::repo_lookup_key(&rt.repositories, "Move") else {
        return Vec::new();
    };
    match rt.repositories.get(&key) {
        Some(repo) => repo.all().iter()
            .filter(|s| {
                let st = s.fields.get("status").map(value_to_string).unwrap_or_default();
                st == "applied" || st == "verified"
            })
            .filter(|s| {
                let l = s.fields.get("layout").map(value_to_string).unwrap_or_default();
                l.is_empty() || l == layout_name
            })
            .map(|s| (
                s.fields.get("move_id").map(value_to_string).unwrap_or(s.id.clone()),
                s.fields.get("from").map(value_to_string).unwrap_or_default(),
                s.fields.get("to").map(value_to_string).unwrap_or_default(),
            ))
            .collect(),
        None => Vec::new(),
    }
}

fn collect_moves_for(rt: &Runtime, status: &str, layout_name: &str) -> Vec<(String, String, String)> {
    let Some(key) = crate::runtime::repo_lookup_key(&rt.repositories, "Move") else {
        return Vec::new();
    };
    match rt.repositories.get(&key) {
        Some(repo) => repo.all().iter()
            .filter(|s| s.fields.get("status").map(value_to_string).as_deref() == Some(status))
            .filter(|s| {
                let l = s.fields.get("layout").map(value_to_string).unwrap_or_default();
                l.is_empty() || l == layout_name
            })
            .map(|s| (
                s.fields.get("move_id").map(value_to_string).unwrap_or(s.id.clone()),
                s.fields.get("from").map(value_to_string).unwrap_or_default(),
                s.fields.get("to").map(value_to_string).unwrap_or_default(),
            ))
            .collect(),
        None => Vec::new(),
    }
}

/// Real post-move validation : parse the moved bluebook through the
/// runtime's parser. Returns true on a valid parse with at least one
/// declaration (aggregate / policy / fixture). The file is read from
/// the destination ; if the file is missing or unparseable, validation
/// fails and the caller dispatches FailMove which RevertOnFail rolls
/// back. Skipped for non-.bluebook files (the runner's caller checks
/// the suffix before calling this).
fn validate_bluebook(path: &str) -> bool {
    let Ok(source) = std::fs::read_to_string(path) else { return false };
    let domain = crate::parser::parse(&source);
    !domain.aggregates.is_empty() || !domain.policies.is_empty() || !domain.fixtures.is_empty()
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

/// Glob-style pattern matcher covering the cases real Layouts need :
///
///   `*.ext`               — any file with that extension, any directory
///   `**/*.ext`            — same as above, the `**` made explicit
///   `dir/*.ext`           — a file with that extension whose immediate
///                            parent dir matches `dir` (single segment)
///   `dir/**/*.ext`        — recursive variant : the file lives anywhere
///                            under any directory named `dir`
///   `path/to/specific.bluebook` — exact path-suffix match
///   `name.ext`            — exact filename, any directory
///
/// The path argument is the absolute path of a file ; the matcher
/// compares against the path's components. Designed for the file-place
/// inventory use case ; not a full glob implementation. When patterns
/// outgrow this, we lift to a real globber and the body_kind catalog
/// declaration captures it.
fn matches_pattern(path: &Path, pattern: &str) -> bool {
    let p_str = path.to_string_lossy();
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");

    // Bare extension globs : `*.ext` or `**/*.ext`.
    let bare_ext = pattern.strip_prefix("*.")
        .or_else(|| pattern.strip_prefix("**/*."));
    if let Some(suffix) = bare_ext {
        return name.ends_with(&format!(".{}", suffix));
    }

    // Path-prefixed globs : `dir/*.ext` or `dir/**/*.ext`.
    if let Some((prefix, rest)) = pattern.split_once('/') {
        if let Some(ext_glob) = rest.strip_prefix("**/*.") {
            // Recursive : any segment named `prefix` anywhere in the path
            // and the file ends with `.ext`.
            let has_prefix_segment = path.components()
                .any(|c| c.as_os_str().to_str() == Some(prefix));
            return has_prefix_segment && name.ends_with(&format!(".{}", ext_glob));
        }
        if let Some(ext_glob) = rest.strip_prefix("*.") {
            // Single-segment : immediate parent dir matches prefix.
            let parent_name = path.parent()
                .and_then(|p| p.file_name())
                .and_then(|n| n.to_str())
                .unwrap_or("");
            return parent_name == prefix && name.ends_with(&format!(".{}", ext_glob));
        }
        // Literal multi-segment path : suffix match.
        return p_str.ends_with(pattern);
    }

    // Exact filename, any directory.
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

fn fs_root_from_registry(registry: &AdapterRegistry) -> Option<PathBuf> {
    let fs = registry.io("fs")?;
    let (_, root) = fs.options.iter().find(|(k, _)| k == "root")?;
    Some(PathBuf::from(root.trim_matches('"')))
}
