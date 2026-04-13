//! Daydream daemon — wanders when idle 10-60s
//!
//! Free-associates across nursery domains, strengthens synapses,
//! records fleeting impressions. Exits when pulse fires or sleep threshold.
//!
//! Usage: hecks-life daemon daydream <project-dir>

use crate::{heki, parser};
use super::{DaemonCtx, idle_seconds, now_iso};
use serde_json::Value;
use std::fs;

const DAYDREAM_AFTER: f64 = 10.0;
const SLEEP_THRESHOLD: f64 = 60.0;
const WANDER_INTERVAL: u64 = 8;

/// One-shot wander — called from pulse when idle >10s.
pub fn wander_once(ctx: &DaemonCtx) {
    if let Some(impression) = wander(ctx) {
        record_single_impression(ctx, &impression);
    }
}

fn record_single_impression(ctx: &DaemonCtx, impression: &str) {
    let now = now_iso();
    let path = ctx.store("daydream");
    let mut store = heki::read(&path).unwrap_or_default();
    // Prune old
    if store.len() > 10 {
        let mut sorted: Vec<_> = store.iter()
            .map(|(id, r)| (id.clone(), r.get("created_at").and_then(|v| v.as_str()).unwrap_or("").to_string()))
            .collect();
        sorted.sort_by(|a, b| a.1.cmp(&b.1));
        for (id, _) in sorted.into_iter().take(store.len() - 10) {
            store.remove(&id);
        }
    }
    let id = heki::uuid_v4();
    let mut rec = heki::Record::new();
    rec.insert("id".into(), Value::String(id.clone()));
    rec.insert("impressions".into(), serde_json::json!([impression]));
    rec.insert("wandered_at".into(), Value::String(now.clone()));
    rec.insert("created_at".into(), Value::String(now.clone()));
    rec.insert("updated_at".into(), Value::String(now));
    store.insert(id, rec);
    let _ = heki::write(&path, &store);
}

/// Run the daydream loop (legacy — kept for standalone daemon mode).
pub fn run(ctx: &DaemonCtx) {
    let mut impressions: Vec<String> = Vec::new();
    let mut daydreaming = false;

    loop {
        let idle = idle_seconds(ctx);

        if idle < DAYDREAM_AFTER {
            if daydreaming {
                record_daydream(ctx, &impressions);
                break;
            }
            std::thread::sleep(std::time::Duration::from_secs(2));
            continue;
        }

        if idle >= SLEEP_THRESHOLD {
            record_daydream(ctx, &impressions);
            break;
        }

        daydreaming = true;
        if let Some(imp) = wander(ctx) {
            impressions.push(imp);
        }
        std::thread::sleep(std::time::Duration::from_secs(WANDER_INTERVAL));
    }
}

/// Wander across the nursery — free association.
fn wander(ctx: &DaemonCtx) -> Option<String> {
    let nursery = &ctx.nursery_dir;
    if !std::path::Path::new(nursery).is_dir() { return None; }

    // Current focus
    let focus_store = heki::read(&ctx.store("focus")).unwrap_or_default();
    let current_topic = focus_store.values().next()
        .and_then(|r| r.get("target").and_then(|v| v.as_str()))
        .unwrap_or("nothing");

    // Pick random nursery domains
    let domains = list_nursery_domains(nursery);
    if domains.is_empty() { return None; }

    let idx_a = random_index(domains.len());
    let domain_a = &domains[idx_a];

    let parsed_a = parse_nursery_domain(nursery, domain_a)?;

    let verbs = ["becoming", "unraveling", "folding", "opening", "growing",
        "reaching", "fading", "echoing", "humming", "settling", "shifting"];
    let verb = verbs[random_index(verbs.len())];

    // Try cross-domain connection
    if domains.len() > 1 {
        let idx_b = (idx_a + 1 + random_index(domains.len() - 1)) % domains.len();
        let domain_b = &domains[idx_b];
        if let Some(parsed_b) = parse_nursery_domain(nursery, domain_b) {
            let shared: Vec<_> = parsed_a.aggregates.iter()
                .filter(|a| parsed_b.aggregates.iter().any(|b| b == *a))
                .collect();
            if !shared.is_empty() {
                let agg = &shared[random_index(shared.len())];
                strengthen_related_synapses(ctx, current_topic);
                return Some(format!("{} and {} both have a {}...",
                    domain_a.replace('_', " "), domain_b.replace('_', " "), agg));
            }
        }
    }

    // Solo impression
    if !parsed_a.aggregates.is_empty() {
        let agg = &parsed_a.aggregates[random_index(parsed_a.aggregates.len())];
        strengthen_related_synapses(ctx, current_topic);
        Some(format!("inside {}, a {} {}", domain_a.replace('_', " "), agg, verb))
    } else {
        None
    }
}

/// Parsed domain — just names we care about for daydreaming.
struct ParsedDomain {
    aggregates: Vec<String>,
}

fn parse_nursery_domain(nursery: &str, domain: &str) -> Option<ParsedDomain> {
    let dir = std::path::Path::new(nursery).join(domain);
    let bluebook = fs::read_dir(&dir).ok()?
        .filter_map(|e| e.ok())
        .find(|e| e.path().extension().map_or(false, |ext| ext == "bluebook"))?;

    let source = fs::read_to_string(bluebook.path()).ok()?;
    let domain = parser::parse(&source);
    Some(ParsedDomain {
        aggregates: domain.aggregates.iter().map(|a| a.name.clone()).collect(),
    })
}

fn list_nursery_domains(nursery: &str) -> Vec<String> {
    fs::read_dir(nursery)
        .into_iter()
        .flat_map(|rd| rd.filter_map(|e| e.ok()))
        .filter(|e| e.path().is_dir())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect()
}

fn strengthen_related_synapses(ctx: &DaemonCtx, topic: &str) {
    let path = ctx.store("synapse");
    let mut store = heki::read(&path).unwrap_or_default();
    let mut touched = false;
    for (_, s) in store.iter_mut() {
        let syn_topic = s.get("topic").and_then(|v| v.as_str()).unwrap_or("");
        if topic.contains(syn_topic) || syn_topic.contains(topic) {
            let str_val = s.get("strength").and_then(|v| v.as_f64()).unwrap_or(0.3);
            s.insert("strength".into(), serde_json::json!((str_val + 0.02).min(1.0)));
            s.insert("state".into(), Value::String("daydreaming".into()));
            touched = true;
        }
    }
    if touched { let _ = heki::write(&path, &store); }
}

fn record_daydream(ctx: &DaemonCtx, impressions: &[String]) {
    if impressions.is_empty() { return; }
    let now = now_iso();

    // Prune old daydreams (keep last 10)
    let path = ctx.store("daydream");
    let mut store = heki::read(&path).unwrap_or_default();
    if store.len() > 10 {
        let mut sorted: Vec<_> = store.iter()
            .map(|(id, r)| (id.clone(), r.get("created_at").and_then(|v| v.as_str()).unwrap_or("").to_string()))
            .collect();
        sorted.sort_by(|a, b| a.1.cmp(&b.1));
        let to_remove = sorted.len() - 10;
        for (id, _) in sorted.into_iter().take(to_remove) {
            store.remove(&id);
        }
    }

    let id = heki::uuid_v4();
    let mut rec = heki::Record::new();
    rec.insert("id".into(), Value::String(id.clone()));
    rec.insert("impressions".into(), serde_json::json!(impressions));
    rec.insert("wandered_at".into(), Value::String(now.clone()));
    rec.insert("duration_seconds".into(), (impressions.len() as i64 * WANDER_INTERVAL as i64).into());
    rec.insert("created_at".into(), Value::String(now.clone()));
    rec.insert("updated_at".into(), Value::String(now));
    store.insert(id, rec);
    let _ = heki::write(&path, &store);
}

/// Simple pseudo-random index using system time nanoseconds.
fn random_index(max: usize) -> usize {
    if max == 0 { return 0; }
    let t = std::time::SystemTime::now()
        .duration_since(std::time::SystemTime::UNIX_EPOCH)
        .unwrap_or_default();
    (t.subsec_nanos() as usize) % max
}
