//! Boot capability runner — walks `capabilities/boot/boot.bluebook`'s
//! eight pipeline phases and dispatches each through the declared
//! adapters (`:fs`, `:stdout`, `:memory`, `:daemon`).
//!
//! Mirrors `run_status/` in shape : capability detection on the parsed
//! bluebook + hecksagon, then a phase-by-phase dispatch that updates
//! the BootRun aggregate state and emits the chained events declared
//! in the bluebook's policies.
//!
//! Fires when the bluebook declares aggregate `BootRun` with command
//! `BeginBoot` AND the hecksagon declares `:fs` + `:stdout` adapters.
//! When detected, [`run`] takes over from the generic dispatcher in
//! `run.rs` and walks the pipeline:
//!
//!   1. DiscoverOrgans       — `:fs` walks aggregates/ + capabilities/
//!   2. WriteCensus          — `:memory` upserts census.heki
//!   3. ClassifyStores       — `:fs` walks *.heki, classifies linked /
//!                              private / unclassified
//!   4. GenerateSystemPrompt — DEFERRED ; the shell still owns this
//!                              until i89 lifts the prompt body into
//!                              identity fixtures (see runtime gaps
//!                              note in vitals.rs).
//!   5. RecordBootJournal    — DEFERRED ; aggregates/boot.bluebook
//!                              isn't loaded by this runner today
//!                              (see runtime gaps note).
//!   6. EnsureDaemons        — `:daemon` shells out to
//!                              `hecks-life daemon ensure` per declared
//!                              daemon row in the hecksagon.
//!   7. PrintVitals          — `:stdout` renders the boot summary.
//!   8. SurfaceWakeReport    — `:fs` reads the wake-report heki, prints
//!                              if `phase == "filed"`.
//!
//! Once GenerateSystemPrompt + RecordBootJournal land, `boot_miette.sh`
//! becomes `exec hecks-life run capabilities/boot/boot.bluebook` —
//! one line. Until then, it's the wrapper for those two phases.

mod classify;
mod daemons;
mod discover;
mod vitals;
mod wake;

use crate::run::ExitKind;
use crate::runtime::adapter_registry::AdapterRegistry;
use crate::runtime::{AggregateState, Runtime, Value};

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

/// True when the bluebook + hecksagon shape wants the boot runner.
pub fn is_boot_capability(registry: &AdapterRegistry, rt: &Runtime) -> bool {
    if registry.io("fs").is_none() || registry.io("stdout").is_none() { return false; }
    let has_agg = rt.domain.aggregates.iter().any(|a| a.name == "BootRun");
    let has_cmd = rt.domain.aggregates.iter()
        .any(|a| a.commands.iter().any(|c| c.name == "BeginBoot"));
    has_agg && has_cmd
}

/// Run the boot pipeline end-to-end. `script_path` is the bluebook the
/// caller dispatched against ; it anchors the :fs root + the conception
/// dir walks. `argv_extra` is positional + `key=val` args after the
/// script path — `being=<Name>` overrides the aggregate's default.
pub fn run(
    rt: &mut Runtime,
    registry: &AdapterRegistry,
    entrypoint: &str,
    script_path: &str,
    argv_extra: &[String],
) -> i32 {
    let started = Instant::now();
    let being = parse_being(argv_extra);
    let info_dir = resolve_info_dir(registry, script_path);
    let conception_dir = conception_dir(script_path);

    // Phase 0 : kick the entrypoint so the BootBegun event fires for
    // any subscribed watchers. The aggregate state we stamp at the end
    // overwrites whatever the entrypoint mutates ; the dispatch is
    // here for the event side-effect, not the state.
    let mut attrs = HashMap::new();
    attrs.insert("being".to_string(), Value::Str(being.clone()));
    let _ = rt.dispatch(entrypoint, attrs);

    // Phase 1 — DiscoverOrgans
    let counts = discover::count_organs(&conception_dir);

    // Phase 2 — WriteCensus
    let _ = discover::write_census(&info_dir, &counts);

    // Phase 3 — ClassifyStores
    let classification = classify::classify(&info_dir);

    // Phase 4 — GenerateSystemPrompt : DEFERRED
    //   The printf heredoc in boot_miette.sh is genuine application
    //   logic ; porting it to Rust string literals would just trade
    //   shell loc for Rust loc. i89 lifts the prompt body into
    //   identity fixtures so prompt edits cost zero shell. Until then
    //   the shell wrapper handles this phase.

    // Phase 5 — RecordBootJournal : DEFERRED
    //   aggregates/boot.bluebook declares Identity, Hydration, etc. ;
    //   the runner today loads only the capability's bluebook, not
    //   the aggregates dir. File the gap : "boot runner should also
    //   load the aggregates dir to dispatch journal commands."

    // Phase 6 — EnsureDaemons
    let daemon_statuses = daemons::ensure_all(registry, script_path, &info_dir);

    // Phase 7 — PrintVitals
    let elapsed_secs = started.elapsed().as_secs();
    vitals::print(&vitals::Vitals {
        being: being.clone(),
        elapsed_secs,
        counts: counts.clone(),
        classification: classification.clone(),
        daemons: daemon_statuses.clone(),
        info_dir: info_dir.clone(),
    });

    // Phase 8 — SurfaceWakeReport
    wake::surface(&info_dir);

    // Stamp final state into BootRun for any watchers reading it.
    stamp_aggregate(rt, &being, &info_dir, &counts, &classification, &daemon_statuses);

    ExitKind::Ok.code()
}

/// Pick `being` out of `key=val` argv (default "Miette"). Mirrors the
/// shell's `BEING="${1:-Miette}"` plus argv-style attr passing in run.rs.
fn parse_being(argv: &[String]) -> String {
    for a in argv {
        if let Some(rest) = a.strip_prefix("being=") {
            return rest.to_string();
        }
    }
    // Allow positional too, for parity with `boot_miette.sh Spring`.
    for a in argv {
        if !a.contains('=') && !a.starts_with("--") && !a.is_empty() {
            return a.clone();
        }
    }
    "Miette".to_string()
}

/// `:fs` root resolution — same as run_status, with HECKS_INFO override.
/// Canonicalizes the script path so relative invocations from inside
/// the conception dir still produce absolute paths.
fn resolve_info_dir(registry: &AdapterRegistry, script_path: &str) -> String {
    if let Ok(env) = std::env::var("HECKS_INFO") {
        if !env.is_empty() { return env; }
    }
    let abs = std::fs::canonicalize(script_path)
        .unwrap_or_else(|_| PathBuf::from(script_path));
    let mut cur = abs.parent().unwrap_or_else(|| Path::new(".")).to_path_buf();
    for _ in 0..5 {
        let cand = cur.join("information");
        if cand.is_dir() { return cand.to_string_lossy().into_owned(); }
        if !cur.pop() { break; }
    }
    // Fallback : whatever the :fs adapter declares.
    if let Some(fs) = registry.io("fs") {
        if let Some((_, root)) = fs.options.iter().find(|(k, _)| k == "root") {
            let trimmed = root.trim_matches('"');
            return trimmed.to_string();
        }
    }
    "information".to_string()
}

/// Conception root (sibling of `information/` and `capabilities/`).
/// Canonicalizes for the same reason as [`resolve_info_dir`].
fn conception_dir(script_path: &str) -> PathBuf {
    let abs = std::fs::canonicalize(script_path)
        .unwrap_or_else(|_| PathBuf::from(script_path));
    let mut cur = abs.parent().unwrap_or_else(|| Path::new(".")).to_path_buf();
    for _ in 0..5 {
        if cur.join("information").is_dir() && cur.join("capabilities").is_dir() {
            return cur;
        }
        if !cur.pop() { break; }
    }
    abs.parent().unwrap_or_else(|| Path::new(".")).to_path_buf()
}

/// Stamp the assembled boot state into the BootRun aggregate so any
/// consumer reading `rt.all("BootRun")` sees the same payload the
/// runner printed.
fn stamp_aggregate(
    rt: &mut Runtime,
    being: &str,
    info_dir: &str,
    counts: &discover::OrganCounts,
    cls: &classify::Classification,
    daemons: &[daemons::DaemonStatus],
) {
    let repo = match rt.repositories.get_mut("BootRun") { Some(r) => r, None => return };
    let mut state = AggregateState::new("1");
    state.set("being",                Value::Str(being.into()));
    state.set("info_dir",             Value::Str(info_dir.into()));
    state.set("organ_count",          Value::Int(counts.organs as i64));
    state.set("capability_count",     Value::Int(counts.capabilities as i64));
    state.set("total_aggregates",     Value::Int(counts.aggregates as i64));
    state.set("nerve_count",          Value::Int(counts.nerves as i64));
    state.set("vow_count",            Value::Int(counts.vows as i64));
    state.set("linked_stores",        Value::Str(cls.linked.join(" ")));
    state.set("private_stores",       Value::Str(cls.private_.join(" ")));
    state.set("unclassified_stores",  Value::Str(cls.unclassified.join(" ")));
    for d in daemons {
        let key = format!("{}_status", d.name);
        state.set(&key, Value::Str(d.status.clone()));
    }
    state.set("phase", Value::Str("done".into()));
    repo.save(state, crate::heki::WriteContext::OutOfBand {
        reason: "boot capability runner — writes Boot aggregate state directly; retires when boot.bluebook + capability runner dispatch lands",
    });
}
