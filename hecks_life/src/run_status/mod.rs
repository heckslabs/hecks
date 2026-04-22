//! Status-report capability runner — prints a labeled multi-system
//! status snapshot via the :fs, :shell, and :stdout adapters declared in
//! the hecksagon.
//!
//! Fires when a bluebook's entrypoint is `GenerateReport`, the aggregate
//! `StatusReport` is present, and the hecksagon declares a `:fs` adapter
//! with a `root:` option plus a `:stdout` adapter. The runner then:
//!
//!   1. Resolves the :fs root relative to the script's directory.
//!   2. Reads every referenced <name>.heki store via the heki module.
//!   3. Counts bluebook files under `aggregates/` + `capabilities/` by
//!      walking the script's parent tree (the old status.sh heuristic).
//!   4. Checks `.mindstream.pid` via the declared `is_pid_alive` shell
//!      adapter (`kill -0 <pid>`).
//!   5. Dispatches `GenerateReport` so the aggregate transitions + emits
//!      `StatusReported` for any watchers.
//!   6. Writes the formatted report to the :stdout adapter.
//!
//! The formatting mirrors the old `hecks_conception/status.sh` shell +
//! Python pair: eight sections (Identity, Consciousness, Vitals, Mood,
//! Memory, Recent activity, Bluebooks, Daemons) with bold/yellow headers
//! when the terminal is a TTY and NO_COLOR is unset.

mod assemble;
mod render;

use crate::hecksagon_ir::IoAdapter;
use crate::run::ExitKind;
use crate::runtime::adapter_io::write_stdout;
use crate::runtime::adapter_registry::AdapterRegistry;
use crate::runtime::{AggregateState, Runtime, Value};

use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub use assemble::Report;

/// True when the bluebook + hecksagon shape wants the status runner.
pub fn is_status_report_capability(registry: &AdapterRegistry, rt: &Runtime) -> bool {
    if registry.io("fs").is_none() || registry.io("stdout").is_none() { return false; }
    let has_agg = rt.domain.aggregates.iter().any(|a| a.name == "StatusReport");
    let has_cmd = rt.domain.aggregates.iter()
        .any(|a| a.commands.iter().any(|c| c.name == "GenerateReport"));
    has_agg && has_cmd
}

/// Run the status report end-to-end. `script_path` is the bluebook file
/// the runner was invoked against; it anchors the :fs root + bluebook
/// count. `argv_extra` is positional + `key=val` args after the script
/// path (currently only used for the `--no-color` flag).
pub fn run(
    rt: &mut Runtime,
    registry: &AdapterRegistry,
    entrypoint: &str,
    script_path: &str,
    argv_extra: &[String],
) -> i32 {
    let fs_adapter = registry.io("fs").expect("fs adapter present");
    let stdout = registry.io("stdout").expect("stdout adapter present");
    let no_color = argv_extra.iter().any(|a| a == "--no-color");
    let on = color_enabled(no_color);

    let info_dir = resolve_fs_root(fs_adapter, script_path);
    let conception_dir = conception_dir(script_path);

    // Assemble the report into the StatusReport aggregate state so
    // consumers of `rt.all("StatusReport")` see the exact same payload
    // the runner is about to print.
    let report = assemble::build(&info_dir, &conception_dir, registry);
    stamp_aggregate(rt, &report);

    let _ = rt.dispatch(entrypoint, HashMap::new());

    for line in render::render(&report, on) {
        let empty = HashMap::new();
        write_stdout(stdout, &line, &empty);
    }

    ExitKind::Ok.code()
}

fn stamp_aggregate(rt: &mut Runtime, r: &Report) {
    let repo = match rt.repositories.get_mut("StatusReport") { Some(r) => r, None => return };
    let mut state = AggregateState::new("1");
    state.set("identity_name",       Value::Str(r.identity_name.clone()));
    state.set("consciousness_state", Value::Str(r.consciousness_state.clone()));
    state.set("sleep_stage",         Value::Str(r.sleep_stage.clone()));
    state.set("sleep_progress",      Value::Str(r.sleep_progress.clone()));
    state.set("sleep_summary",       Value::Str(r.sleep_summary.clone()));
    state.set("fatigue",             Value::Str(r.fatigue.clone()));
    state.set("fatigue_state",       Value::Str(r.fatigue_state.clone()));
    state.set("pulse_rate",          Value::Str(r.pulse_rate.clone()));
    state.set("flow_rate",           Value::Str(r.flow_rate.clone()));
    state.set("pulses_since_sleep",  Value::Str(r.pulses_since_sleep.clone()));
    state.set("cycle",               Value::Str(r.cycle.clone()));
    state.set("mood_state",          Value::Str(r.mood_state.clone()));
    state.set("creativity_level",    Value::Str(r.creativity_level.clone()));
    state.set("precision_level",     Value::Str(r.precision_level.clone()));
    state.set("musings_count",       Value::Int(r.musings_count as i64));
    state.set("conversations_count", Value::Int(r.conversations_count as i64));
    state.set("signals_count",       Value::Int(r.signals_count as i64));
    state.set("synapses_count",      Value::Int(r.synapses_count as i64));
    state.set("memories_count",      Value::Int(r.memories_count as i64));
    state.set("last_dream_at",       Value::Str(r.last_dream_at.clone()));
    state.set("last_dream_text",     Value::Str(r.last_dream_text.clone()));
    state.set("last_turn_at",        Value::Str(r.last_turn_at.clone()));
    state.set("last_turn_text",      Value::Str(r.last_turn_text.clone()));
    state.set("aggregates_count",    Value::Int(r.aggregates_count as i64));
    state.set("capabilities_count",  Value::Int(r.capabilities_count as i64));
    state.set("mindstream_alive",    Value::Str(if r.mindstream_alive { "alive" } else { "down" }.into()));
    repo.save(state);
}

/// The `:fs` adapter's `root:` option anchors the heki store directory.
/// When relative, we walk up from the script's directory looking for a
/// directory that contains `<root>/` — that's the conception root.
///
/// Reads `HECKS_INFO` from the environment as an override. Tests (e.g.
/// `status_golden.sh`) seed a tmpdir and export `HECKS_INFO=<tmpdir>`
/// so status.sh reads from the seeded dir rather than live state.
fn resolve_fs_root(adapter: &IoAdapter, script_path: &str) -> String {
    let override_dir = std::env::var("HECKS_INFO").ok();
    resolve_fs_root_with(adapter, script_path, override_dir.as_deref())
}

/// Pure core of [`resolve_fs_root`], factored out so tests can inject the
/// override without mutating process-global env. When `env_override` is
/// `Some(non-empty)`, it wins over the hecksagon's `root:` option and the
/// script-dir walk; when unset or empty, behavior is unchanged.
pub(crate) fn resolve_fs_root_with(
    adapter: &IoAdapter,
    script_path: &str,
    env_override: Option<&str>,
) -> String {
    if let Some(v) = env_override {
        if !v.is_empty() { return v.to_string(); }
    }
    let root = adapter.options.iter().find(|(k, _)| k == "root")
        .map(|(_, v)| v.trim_matches('"').to_string())
        .unwrap_or_else(|| "information".to_string());
    if root.starts_with('/') { return root; }
    let script_dir = Path::new(script_path).parent().unwrap_or_else(|| Path::new("."));
    let mut cur: PathBuf = script_dir.to_path_buf();
    for _ in 0..5 {
        let candidate = cur.join(&root);
        if candidate.is_dir() {
            return candidate.to_string_lossy().into_owned();
        }
        if !cur.pop() { break; }
    }
    script_dir.join(&root).to_string_lossy().into_owned()
}

/// Find the conception root (the dir that contains both `information/`
/// and `capabilities/`). Counts of aggregates + capabilities key off it.
fn conception_dir(script_path: &str) -> PathBuf {
    let mut cur = Path::new(script_path).parent().unwrap_or_else(|| Path::new(".")).to_path_buf();
    for _ in 0..5 {
        if cur.join("information").is_dir() && cur.join("capabilities").is_dir() {
            return cur;
        }
        if !cur.pop() { break; }
    }
    Path::new(script_path).parent().unwrap_or_else(|| Path::new(".")).to_path_buf()
}

fn color_enabled(flag_no_color: bool) -> bool {
    if flag_no_color { return false; }
    if std::env::var("NO_COLOR").is_ok() { return false; }
    if std::env::var("HECKS_FORCE_COLOR").as_deref() == Ok("1") { return true; }
    atty_stdout()
}

fn atty_stdout() -> bool {
    // Minimal isatty without pulling a dep: Unix FD 1 isatty via libc.
    #[cfg(unix)]
    unsafe {
        extern "C" { fn isatty(fd: i32) -> i32; }
        isatty(1) != 0
    }
    #[cfg(not(unix))]
    { false }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hecksagon_ir::IoAdapter;

    fn fs_adapter(root: &str) -> IoAdapter {
        let mut a = IoAdapter::default();
        a.kind = "fs".into();
        a.options.push(("root".into(), format!("\"{}\"", root)));
        a
    }

    #[test]
    fn env_override_wins_over_hecksagon_root() {
        let a = fs_adapter("information");
        let out = resolve_fs_root_with(&a, "/tmp/x/script.bluebook", Some("/tmp/seeded"));
        assert_eq!(out, "/tmp/seeded");
    }

    #[test]
    fn empty_env_override_is_ignored() {
        let a = fs_adapter("/abs/root");
        let out = resolve_fs_root_with(&a, "/tmp/x/script.bluebook", Some(""));
        assert_eq!(out, "/abs/root");
    }

    #[test]
    fn absolute_root_used_when_no_override() {
        let a = fs_adapter("/abs/root");
        let out = resolve_fs_root_with(&a, "/tmp/x/script.bluebook", None);
        assert_eq!(out, "/abs/root");
    }
}
