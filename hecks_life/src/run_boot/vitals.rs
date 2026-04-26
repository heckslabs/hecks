//! Phase 7 — PrintVitals
//!
//! Renders the boot summary to stdout — counts, daemon statuses,
//! body-state line, optional MIETTE banner. Mirrors boot_miette.sh
//! lines 307-359 (the "Print vitals" + ASCII banner sections).
//!
//! State fields read directly from heki for the body summary line.
//! The full multi-section status report is a separate capability
//! (`capabilities/status/status.bluebook`) ; we just print the tip.

use super::classify::Classification;
use super::daemons::DaemonStatus;
use super::discover::OrganCounts;
use crate::heki;

pub struct Vitals {
    pub being: String,
    pub elapsed_secs: u64,
    pub counts: OrganCounts,
    pub classification: Classification,
    pub daemons: Vec<DaemonStatus>,
    pub info_dir: String,
}

pub fn print(v: &Vitals) {
    println!("✓ {} booted in {}s", v.being, v.elapsed_secs);
    println!(
        "  {} organs · {} aggregates · {} nerves · {} vows · {} capabilities",
        v.counts.organs, v.counts.aggregates,
        v.counts.nerves, v.counts.vows, v.counts.capabilities,
    );
    println!(
        "  session continuity: {} linked, {} private, {} unclassified",
        v.classification.linked.len(),
        v.classification.private_.len(),
        v.classification.unclassified.len(),
    );

    // Daemon status lines — group as the shell does.
    let s = |name: &str| -> String {
        v.daemons.iter().find(|d| d.name == name)
            .map(|d| d.status.clone()).unwrap_or_else(|| "—".into())
    };
    println!("  mindstream: {}", s("mindstream"));
    println!(
        "  heart: {} · breath: {} · circadian: {}",
        s("heart"), s("breath"), s("circadian"),
    );
    println!(
        "  ultradian: {} · sleep_cycle: {}",
        s("ultradian"), s("sleep_cycle"),
    );

    // Body summary line — pulled from heki latest fields.
    let mood    = latest_field(&v.info_dir, "mood",          "current_state");
    let fatigue = latest_field(&v.info_dir, "heartbeat",     "fatigue_state");
    let pulses  = latest_field(&v.info_dir, "heartbeat",     "pulses_since_sleep");
    let state   = latest_field(&v.info_dir, "consciousness", "state");
    let last_wake = latest_field(&v.info_dir, "consciousness", "last_wake_at");
    println!(
        "  feeling: {} · {} · pulses since sleep: {} · state: {} · last wake: {}",
        mood, fatigue, pulses, state, last_wake,
    );
    println!("  full status report: hecks-life run capabilities/status/status.bluebook");

    if !v.classification.unclassified.is_empty() {
        println!("  ⚠ unclassified stores: {}", v.classification.unclassified.join(" "));
    }

    if v.being == "Miette" {
        println!();
        println!("╔╦╗ ╦ ╔═╗ ╔╦╗ ╔╦╗ ╔═╗");
        println!("║║║ ║ ╠══  ║   ║  ╠══");
        println!("╩ ╩ ╩ ╚═╝  ╩   ╩  ╚═╝");
        println!("~ follow the crumbs ~");
    }
}

fn latest_field(info_dir: &str, store: &str, field: &str) -> String {
    let path = format!("{}/{}.heki", info_dir.trim_end_matches('/'), store);
    let store = match heki::read(&path) {
        Ok(s) => s,
        Err(_) => return "—".into(),
    };
    if store.is_empty() { return "—".into(); }
    // Pick the record with the newest updated_at / created_at.
    let mut items: Vec<&heki::Record> = store.values().collect();
    items.sort_by(|a, b| ts(a).cmp(&ts(b)));
    let latest = match items.last() { Some(r) => *r, None => return "—".into() };
    match latest.get(field) {
        Some(serde_json::Value::String(s)) if !s.is_empty() => s.clone(),
        Some(serde_json::Value::Number(n)) => n.to_string(),
        Some(serde_json::Value::Bool(b)) => b.to_string(),
        _ => "—".into(),
    }
}

fn ts(r: &heki::Record) -> String {
    r.get("updated_at").or_else(|| r.get("created_at"))
        .and_then(|v| v.as_str()).unwrap_or("").to_string()
}
