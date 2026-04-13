//! Mindstream — continuous awareness that never stops
//!
//! A loop that runs as fast as Rust allows. Each tick:
//!   - Wanders the nursery (daydream)
//!   - Consolidates signals into memories
//!   - Dreams — recombines concepts, strengthens synapses
//!   - Prunes dead connections, composts remains
//!
//! Stops the instant a pulse fires (Winter is prompted).
//! At 2ms per cycle, 10 seconds of idle = 5,000 cycles.
//!
//! Usage: hecks-life daemon mindstream <project-dir>

use crate::heki::{self, Record};
use super::{DaemonCtx, idle_seconds, now_iso};
use serde_json::Value;

const MIN_IDLE: f64 = 5.0;

/// Run the mindstream. Loops until a pulse fires.
pub fn run(ctx: &DaemonCtx) {
    let mut cycles: u64 = 0;
    let mut total_consolidated: usize = 0;
    let mut total_pruned: usize = 0;
    let mut images_generated: usize = 0;
    let stream_started = now_iso();

    upsert(ctx, "consciousness", "state", "mindstream");

    loop {
        let idle = idle_seconds(ctx);

        // Not idle enough — haven't been away long
        if idle < MIN_IDLE {
            if cycles > 0 {
                // Pulse fired — Winter is back. Record and exit.
                record_stream(ctx, &stream_started, cycles,
                    total_consolidated, total_pruned, images_generated);
                recover_fatigue(ctx, cycles);
                upsert(ctx, "consciousness", "state", "attentive");
                eprintln!("  mindstream: {} cycles, {} consolidated, {} pruned, {} images",
                    cycles, total_consolidated, total_pruned, images_generated);
                break;
            }
            // Waiting to start — check every 100ms
            std::thread::sleep(std::time::Duration::from_millis(100));
            continue;
        }

        // === One cycle of the mindstream ===

        // Wander — free-associate across nursery
        super::daydream::wander_once(ctx);

        // Consolidate — compress old signals into memories
        let (consolidated, pruned) = deep_consolidation(ctx);
        total_consolidated += consolidated;
        total_pruned += pruned.len();

        // Dream — recombine concepts with nursery domains
        let topics = gather_unconceived(ctx);
        let (images, _) = dream_cycle(ctx, &topics, cycles);
        images_generated += images.len();

        // Record dream images periodically (every 100 cycles)
        if cycles % 100 == 0 && !images.is_empty() {
            let mut dream = Record::new();
            dream.insert("dream_images".into(), serde_json::json!(images));
            dream.insert("cycle".into(), (cycles as i64).into());
            dream.insert("source".into(), Value::String("mindstream".into()));
            let _ = heki::append(&ctx.store("dream_state"), &dream);
        }

        // Update mood based on depth
        let mood = match cycles {
            0..=100 => ("drifting", 0.5, 0.5),
            101..=1000 => ("flowing", 0.7, 0.4),
            1001..=5000 => ("deep", 0.8, 0.3),
            _ => ("oceanic", 0.9, 0.2),
        };
        if cycles % 500 == 0 {
            upsert_mood(ctx, mood.0, mood.1, mood.2);
        }

        cycles += 1;

        // Tiny yield — let the OS breathe, but stay fast
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
}

fn gather_unconceived(ctx: &DaemonCtx) -> Vec<String> {
    let musings = heki::read(&ctx.store("musing")).unwrap_or_default();
    musings.values()
        .filter(|m| m.get("conceived").and_then(|v| v.as_bool()) == Some(false))
        .filter_map(|m| m.get("idea").and_then(|v| v.as_str()).map(String::from))
        .collect::<Vec<_>>()
        .into_iter().rev().take(10).collect()
}

fn dream_cycle(ctx: &DaemonCtx, topics: &[String], cycle: u64) -> (Vec<String>, usize) {
    let nursery = &ctx.nursery_dir;
    let domains = list_domains(nursery);
    if domains.is_empty() || topics.is_empty() { return (vec![], 0); }

    let idx = cycle as usize;
    let concept = &topics[idx % topics.len()];
    let domain = &domains[idx % domains.len()];
    let words: Vec<&str> = domain.split('_').collect();

    let dream_verbs = ["dissolving", "growing", "floating", "merging",
        "spiraling", "folding", "crystallizing", "branching", "grafting", "becoming"];
    let verb = dream_verbs[idx % dream_verbs.len()];

    let image = match idx % 4 {
        0 => format!("A {} {}", words.join(" "), verb),
        1 => format!("{} everywhere, {} through {}", concept, verb, words.join(" ")),
        2 => format!("{} made entirely of {}", words.join(" "), concept),
        _ => format!("{} and {} — same shape", concept, words.join(" ")),
    };

    // Strengthen related synapses
    let syn_path = ctx.store("synapse");
    let mut synapses = heki::read(&syn_path).unwrap_or_default();
    let mut touched = false;
    for (_, s) in synapses.iter_mut() {
        let t = s.get("topic").and_then(|v| v.as_str()).unwrap_or("");
        if concept.contains(t) || t.contains(concept.as_str()) {
            let str_val = s.get("strength").and_then(|v| v.as_f64()).unwrap_or(0.3);
            s.insert("strength".into(), serde_json::json!((str_val + 0.01).min(1.0)));
            s.insert("state".into(), Value::String("mindstream".into()));
            touched = true;
        }
    }
    if touched { let _ = heki::write(&syn_path, &synapses); }

    (vec![image], 1)
}

/// Deep consolidation — same as sleep but runs every cycle.
fn deep_consolidation(ctx: &DaemonCtx) -> (usize, Vec<String>) {
    let now = now_iso();
    let sig_path = ctx.store("signal");
    let store = heki::read(&sig_path).unwrap_or_default();
    let mut consolidated = 0;

    if store.len() > 10 {
        let mut sorted: Vec<_> = store.iter().collect();
        sorted.sort_by_key(|(_, s)| s.get("created_at").and_then(|v| v.as_str()).unwrap_or("").to_string());
        let old: Vec<_> = sorted[..sorted.len().saturating_sub(10)].iter()
            .filter(|(_, s)| s.get("access_count").and_then(|v| v.as_i64()).unwrap_or(0) < 2)
            .map(|(id, s)| ((*id).clone(), s.get("payload").and_then(|v| v.as_str()).unwrap_or("").to_string()))
            .collect();
        if !old.is_empty() {
            let payloads: Vec<&str> = old.iter().map(|(_, p)| p.as_str()).collect();
            let mut mem = Record::new();
            mem.insert("domain_name".into(), Value::String("Mindstream".into()));
            mem.insert("persona".into(), Value::String("Winter".into()));
            mem.insert("summary".into(), Value::String(payloads.join(" → ")));
            mem.insert("signal_count".into(), (old.len() as i64).into());
            mem.insert("consolidated_at".into(), Value::String(now.clone()));
            let _ = heki::append(&ctx.store("memory"), &mem);
            consolidated = old.len();

            let ids: Vec<_> = old.iter().map(|(id, _)| id.clone()).collect();
            let mut new_store = store;
            for id in ids { new_store.remove(&id); }
            let _ = heki::write(&sig_path, &new_store);
        }
    }

    // Prune dead synapses
    let syn_path = ctx.store("synapse");
    let mut synapses = heki::read(&syn_path).unwrap_or_default();
    let dead: Vec<(String, String)> = synapses.iter()
        .filter(|(_, s)| s.get("strength").and_then(|v| v.as_f64()).unwrap_or(0.0) < 0.1)
        .map(|(id, s)| (id.clone(), s.get("topic").and_then(|v| v.as_str()).unwrap_or("").to_string()))
        .collect();
    let pruned: Vec<String> = dead.iter().map(|(_, t)| t.clone()).collect();
    for (id, topic) in &dead {
        let mut remains = Record::new();
        remains.insert("source_domain".into(), Value::String(topic.clone().into()));
        remains.insert("died_at".into(), Value::String(now.clone()));
        remains.insert("decomposed".into(), Value::Bool(true));
        let _ = heki::append(&ctx.store("remains"), &remains);
        synapses.remove(id);
    }
    if !dead.is_empty() { let _ = heki::write(&syn_path, &synapses); }

    (consolidated, pruned)
}

fn recover_fatigue(ctx: &DaemonCtx, cycles: u64) {
    let path = ctx.store("pulse");
    let mut store = heki::read(&path).unwrap_or_default();
    if let Some(rec) = store.values_mut().next() {
        let pss = rec.get("pulses_since_sleep").and_then(|v| v.as_i64()).unwrap_or(0);
        // More cycles = more recovery, capped at full
        let recovery_pct = (cycles as f64 / 1000.0).min(1.0);
        let remaining = (pss as f64 * (1.0 - recovery_pct)) as i64;
        rec.insert("pulses_since_sleep".into(), remaining.max(0).into());
        rec.insert("fatigue".into(), serde_json::json!((remaining as f64 / 300.0).min(1.0)));
        let state = match remaining {
            0..=50 => "alert", 51..=100 => "focused", 101..=150 => "normal",
            151..=200 => "tired", _ => "exhausted",
        };
        rec.insert("fatigue_state".into(), Value::String(state.into()));
        rec.insert("updated_at".into(), Value::String(now_iso().into()));
        let _ = heki::write(&path, &store);
    }
}

fn record_stream(ctx: &DaemonCtx, started: &str, cycles: u64,
    consolidated: usize, pruned: usize, images: usize) {
    let mut rec = Record::new();
    rec.insert("started_at".into(), Value::String(started.into()));
    rec.insert("ended_at".into(), Value::String(now_iso().into()));
    rec.insert("cycles".into(), (cycles as i64).into());
    rec.insert("consolidated".into(), (consolidated as i64).into());
    rec.insert("pruned".into(), (pruned as i64).into());
    rec.insert("images_generated".into(), (images as i64).into());
    let _ = heki::append(&ctx.store("dream_state"), &rec);
}

fn upsert(ctx: &DaemonCtx, store: &str, key: &str, val: &str) {
    let mut attrs = Record::new();
    attrs.insert(key.into(), Value::String(val.into()));
    let _ = heki::upsert(&ctx.store(store), &attrs);
}

fn upsert_mood(ctx: &DaemonCtx, state: &str, creativity: f64, precision: f64) {
    let mut attrs = Record::new();
    attrs.insert("current_state".into(), Value::String(state.into()));
    attrs.insert("creativity_level".into(), serde_json::json!(creativity));
    attrs.insert("precision_level".into(), serde_json::json!(precision));
    let _ = heki::upsert(&ctx.store("mood"), &attrs);
}

fn list_domains(nursery: &str) -> Vec<String> {
    std::fs::read_dir(nursery).into_iter()
        .flat_map(|rd| rd.filter_map(|e| e.ok()))
        .filter(|e| e.path().is_dir())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect()
}
