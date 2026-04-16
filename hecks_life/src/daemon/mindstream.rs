//! Mindstream — continuous awareness that never stops
//!
//! A loop that runs as fast as Rust allows. Each tick:
//!   - Wanders the nursery (daydream)
//!   - Consolidates signals into memories
//!   - Dreams — recombines concepts, strengthens synapses
//!   - Prunes dead connections, composts remains
//!
//! Stops the instant a pulse fires (Miette is prompted).
//! At 2ms per cycle, 10 seconds of idle = 5,000 cycles.
//!
//! Usage: hecks-life daemon mindstream <project-dir>

use crate::heki::{self, Record};
use super::{DaemonCtx, idle_seconds, now_iso};
use serde_json::Value;
use std::fs;

const MIN_IDLE: f64 = 30.0;
const SUMMARY_PATH: &str = "/tmp/miette_state/last_mindstream.json";

/// Run the mindstream. Never exits — the unconscious is always running.
/// Works fast when idle, slows to a murmur when active, but never stops.
pub fn run(ctx: &DaemonCtx) {
    let mut cycles: u64 = 0;
    let mut total_consolidated: usize = 0;
    let mut total_pruned: usize = 0;
    let mut images_generated: usize = 0;
    let mut all_images: Vec<String> = Vec::new();
    let mut strongest_synapse: Option<(String, f64)> = None;
    let mut session_start = now_iso();
    let mut was_idle = false;
    let mut thought_queue: Vec<String> = Vec::new();

    loop {
        let idle = idle_seconds(ctx);
        let active = idle < MIN_IDLE;

        // Track idle/active transitions
        if active && was_idle && cycles > 0 {
            record_stream(ctx, &session_start, cycles,
                total_consolidated, total_pruned, images_generated);
            recover_fatigue(ctx, cycles);
            // Interpret accumulated dream images → propose musings
            super::dream_interpret::interpret_and_propose(ctx);
            write_return_summary(cycles, total_consolidated, total_pruned,
                images_generated, &all_images, &strongest_synapse, &session_start);
            was_idle = false;
        }
        if !active && !was_idle {
            was_idle = true;
            session_start = now_iso();
        }

        // === One cycle of the mindstream ===

        // Wander — free-associate across nursery
        super::daydream::wander_once(ctx);

        // Consolidate — compress old signals into memories
        let (consolidated, pruned) = deep_consolidation(ctx);
        total_consolidated += consolidated;
        total_pruned += pruned.len();

        // Dream — recombine concepts with nursery domains
        let topics = gather_concepts(ctx);
        let (images, _) = dream_cycle(ctx, &topics, cycles);
        images_generated += images.len();
        if !images.is_empty() {
            all_images.extend(images.clone());
            // Keep last 20
            if all_images.len() > 20 {
                all_images = all_images[all_images.len()-20..].to_vec();
            }
        }

        // Track strongest synapse touched this session
        let syn_path = ctx.store("synapse");
        let synapses = heki::read(&syn_path).unwrap_or_default();
        if let Some(strongest) = synapses.values()
            .filter(|s| s.get("state").and_then(|v| v.as_str()) == Some("mindstream"))
            .max_by(|a, b| {
                let sa = a.get("strength").and_then(|v| v.as_f64()).unwrap_or(0.0);
                let sb = b.get("strength").and_then(|v| v.as_f64()).unwrap_or(0.0);
                sa.partial_cmp(&sb).unwrap_or(std::cmp::Ordering::Equal)
            }) {
            let topic = strongest.get("topic").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let str_val = strongest.get("strength").and_then(|v| v.as_f64()).unwrap_or(0.0);
            strongest_synapse = Some((topic, str_val));
        }

        // Record dream images every 3 cycles (~30s)
        if cycles % 3 == 0 && !images.is_empty() {
            let mut dream = Record::new();
            dream.insert("dream_images".into(), serde_json::json!(images));
            dream.insert("cycle".into(), (cycles as i64).into());
            dream.insert("source".into(), Value::String("mindstream".into()));
            let _ = heki::append(&ctx.store("dream_state"), &dream);
        }

        // Update mood and consciousness based on depth
        // Thresholds tuned for 10s/cycle: ~1min, ~10min, ~50min
        let (mood_name, creativity, precision) = match cycles {
            0..=6 => ("drifting", 0.5, 0.5),
            7..=60 => ("flowing", 0.7, 0.4),
            61..=300 => ("deep", 0.8, 0.3),
            _ => ("oceanic", 0.9, 0.2),
        };
        if cycles % 3 == 0 {
            upsert_mood(ctx, mood_name, creativity, precision);
        }
        // Write current thought to consciousness — the statusline script
        // decides whether to show it based on heartbeat idle time.
        // Thoughts come from Summer (ollama) in batches of 20.
        // When exhausted, generate a new batch.
        if thought_queue.is_empty() {
            thought_queue = generate_thoughts(ctx);
        }
        if let Some(thought) = thought_queue.pop() {
            write_consciousness(ctx, "wandering", &thought);
        }

        cycles += 1;

        // Yield — breathe between cycles
        std::thread::sleep(std::time::Duration::from_secs(10));
    }
}

/// Ask Summer (ollama) for 20 unique thoughts about nursery domains.
/// Falls back to domain names if ollama isn't available.
fn generate_thoughts(ctx: &DaemonCtx) -> Vec<String> {
    let domains = list_domains(&ctx.nursery_dir);
    if domains.is_empty() { return vec!["quiet mind".into()]; }

    // Pick 10 random domains as seed material
    let now = std::time::SystemTime::now()
        .duration_since(std::time::SystemTime::UNIX_EPOCH)
        .unwrap_or_default().as_secs();
    let mut seeds: Vec<&str> = Vec::new();
    for i in 0..10 {
        let idx = ((now + i) as usize) % domains.len();
        seeds.push(&domains[idx]);
    }
    let seed_list = seeds.iter()
        .map(|d| d.replace('_', " "))
        .collect::<Vec<_>>()
        .join(", ");

    let prompt = format!(
        "Domains: {}\n\n\
         Write 20 lines. Each line combines 2-3 of the above domains \
         into one short idea (under 60 characters). \
         Example: \"wine tracking meets smart HVAC in the cellar\"\n\
         No numbering. No bullets. Just the ideas.",
        seed_list
    );

    // Call ollama — use bluebook-architect (Summer) or fall back to qwen3
    let body = serde_json::json!({
        "model": "bluebook-architect",
        "prompt": prompt,
        "stream": false,
        "options": { "temperature": 1.0, "num_predict": 800 }
    });

    let result = std::process::Command::new("curl")
        .args(["-s", "-X", "POST", "http://localhost:11434/api/generate",
               "-d", &body.to_string()])
        .output();

    if let Ok(output) = result {
        if let Ok(json) = serde_json::from_slice::<Value>(&output.stdout) {
            if let Some(text) = json.get("response").and_then(|v| v.as_str()) {
                let thoughts: Vec<String> = text.lines()
                    .map(|l| l.trim().to_string())
                    .filter(|l| !l.is_empty() && l.len() < 80 && l.len() > 5)
                    .collect();
                if !thoughts.is_empty() {
                    return thoughts;
                }
            }
        }
    }

    // Fallback: just use domain names shuffled
    let mut fallback: Vec<String> = domains.iter()
        .map(|d| d.replace('_', " "))
        .collect();
    fallback.sort_by(|a, b| {
        let ha = a.len().wrapping_mul(now as usize % 97);
        let hb = b.len().wrapping_mul(now as usize % 97);
        ha.cmp(&hb)
    });
    fallback.into_iter().take(20).collect()
}

fn gather_concepts(ctx: &DaemonCtx) -> Vec<String> {
    let mut concepts: Vec<String> = Vec::new();

    // Unconceived musings (short ones)
    let musings = heki::read(&ctx.store("musing")).unwrap_or_default();
    concepts.extend(musings.values()
        .filter(|m| m.get("conceived").and_then(|v| v.as_bool()) != Some(true))
        .filter(|m| m.get("source").and_then(|v| v.as_str()) != Some("mindstream"))
        .filter_map(|m| m.get("idea").and_then(|v| v.as_str()).map(String::from))
        .filter(|s| s.split_whitespace().count() <= 4));

    // Conceived musings — ideas that became real, still good material
    concepts.extend(musings.values()
        .filter(|m| m.get("conceived_as").and_then(|v| v.as_str()).unwrap_or("") != "dismissed")
        .filter(|m| m.get("conceived").and_then(|v| v.as_bool()) == Some(true))
        .filter_map(|m| m.get("conceived_as").and_then(|v| v.as_str()).map(String::from)));

    // Nursery domain names as concepts
    let domains = list_domains(&ctx.nursery_dir);
    concepts.extend(domains.iter().take(10).map(|d| d.replace('_', " ")));

    // Synapse topics
    let synapses = heki::read(&ctx.store("synapse")).unwrap_or_default();
    concepts.extend(synapses.values()
        .filter(|s| s.get("strength").and_then(|v| v.as_f64()).unwrap_or(0.0) > 0.3)
        .filter_map(|s| s.get("topic").and_then(|v| v.as_str()).map(String::from))
        .take(5));

    concepts.dedup();
    concepts.into_iter().rev().take(15).collect()
}

fn dream_cycle(ctx: &DaemonCtx, topics: &[String], cycle: u64) -> (Vec<String>, usize) {
    let nursery = &ctx.nursery_dir;
    let domains = list_domains(nursery);
    if domains.is_empty() || topics.is_empty() { return (vec![], 0); }

    let idx = cycle as usize;
    // Pick 2-3 concepts and 1-2 domains for combinatorial weaving
    let concept_a = &topics[idx % topics.len()];
    let concept_b = &topics[(idx + 3) % topics.len()];
    let domain_a = &domains[idx % domains.len()];
    let domain_b = &domains[(idx + 1) % domains.len()];
    let words_a: Vec<&str> = domain_a.split('_').collect();
    let words_b: Vec<&str> = domain_b.split('_').collect();

    // Dream images weave multiple ideas together — no narration verbs
    let image = match idx % 5 {
        0 => format!("{}, {}, {}", concept_a, concept_b, words_a.join(" ")),
        1 => format!("{} and {} braided inside {}", words_a.join(" "), words_b.join(" "), concept_a),
        2 => format!("{} made of {} and {}", words_a.join(" "), concept_a, concept_b),
        3 => format!("{} where {} meets {} meets {}", words_a.join(" "), concept_a, concept_b, words_b.join(" ")),
        _ => format!("{} and {} — {} holds them both", concept_a, concept_b, words_a.join(" ")),
    };

    // Strengthen synapses for ALL concepts touched this cycle
    let syn_path = ctx.store("synapse");
    let mut synapses = heki::read(&syn_path).unwrap_or_default();
    let mut touched = false;
    for (_, s) in synapses.iter_mut() {
        let t = s.get("topic").and_then(|v| v.as_str()).unwrap_or("");
        if concept_a.contains(t) || t.contains(concept_a.as_str())
            || concept_b.contains(t) || t.contains(concept_b.as_str()) {
            let str_val = s.get("strength").and_then(|v| v.as_f64()).unwrap_or(0.3);
            s.insert("strength".into(), serde_json::json!((str_val + 0.01).min(1.0)));
            s.insert("state".into(), Value::String("mindstream".into()));
            touched = true;
        }
    }
    if touched { let _ = heki::write(&syn_path, &synapses); }

    // Every 12 cycles (~2 minutes at 10s/cycle), mint a combinatorial musing
    if cycle % 12 == 0 && cycle > 0 {
        maybe_mint_musing(ctx, topics, &domains, cycle);
        prune_repetitive_musings(ctx);
    }

    (vec![image], 1)
}

/// Mint a new musing by weaving multiple concepts and domains together.
/// Combinatorial: A+B+C→insight, not A vs B.
fn maybe_mint_musing(ctx: &DaemonCtx, topics: &[String], domains: &[String], cycle: u64) {
    let musings = heki::read(&ctx.store("musing")).unwrap_or_default();
    let idx = cycle as usize;

    // Pick 2-3 ingredients from different pools
    let c1 = &topics[idx % topics.len()];
    let c2 = &topics[(idx + 2) % topics.len()];
    let d1 = domains[idx % domains.len()].replace('_', " ");
    let d2 = domains[(idx + 1) % domains.len()].replace('_', " ");

    // Skip if concepts are the same or too short
    if c1 == c2 || c1.len() < 5 { return; }

    // Check for existing musings containing the same combination
    let already_exists = musings.values().any(|m| {
        let idea = m.get("idea").and_then(|v| v.as_str()).unwrap_or("");
        idea.contains(c1.as_str()) && idea.contains(c2.as_str())
    });
    if already_exists { return; }

    // Combinatorial templates — always weave 2+ ideas
    let templates: Vec<String> = vec![
        format!("{} and {} through the lens of {}", c1, c2, d1),
        format!("{} where {} meets {} — what emerges?", d1, c1, c2),
        format!("{} braided with {} inside {}", c1, d1, c2),
        format!("{} and {} as one capability, shaped by {}", d1, d2, c1),
        format!("what if {} held {} and {} at the same time?", d1, c1, c2),
    ];
    let idea = &templates[idx % templates.len()];

    let mut rec = Record::new();
    rec.insert("idea".into(), Value::String(idea.clone()));
    rec.insert("conceived".into(), Value::Bool(false));
    rec.insert("source".into(), Value::String("mindstream".into()));
    let _ = heki::append(&ctx.store("musing"), &rec);
}

/// Prune repetitive mindstream musings — if the same concept appears
/// in more than 3 musings, dismiss the extras. Keep the most recent 3.
fn prune_repetitive_musings(ctx: &DaemonCtx) {
    let path = ctx.store("musing");
    let mut store = heki::read(&path).unwrap_or_default();
    let mut changed = false;

    // Group mindstream musings by concept (last word in the idea)
    let mindstream_ids: Vec<(String, String)> = store.iter()
        .filter(|(_, m)| m.get("source").and_then(|v| v.as_str()) == Some("mindstream"))
        .filter(|(_, m)| m.get("conceived").and_then(|v| v.as_bool()) != Some(true))
        .map(|(id, m)| {
            let idea = m.get("idea").and_then(|v| v.as_str()).unwrap_or("");
            // Extract the concept — it's the last segment after the verb
            let concept = idea.rsplit_once(' ').map(|(_, c)| c).unwrap_or(idea);
            (id.clone(), concept.to_string())
        })
        .collect();

    // Count per concept
    let mut concept_counts: std::collections::HashMap<String, Vec<String>> = std::collections::HashMap::new();
    for (id, concept) in &mindstream_ids {
        concept_counts.entry(concept.clone()).or_default().push(id.clone());
    }

    // If any concept has more than 3, archive the oldest
    let archive_path = ctx.store("musing_archive");
    for (_, ids) in &concept_counts {
        if ids.len() > 3 {
            let mut with_time: Vec<(&str, String)> = ids.iter()
                .map(|id| {
                    let created = store.get(id)
                        .and_then(|m| m.get("created_at").and_then(|v| v.as_str()))
                        .unwrap_or("").to_string();
                    (id.as_str(), created)
                })
                .collect();
            with_time.sort_by(|a, b| b.1.cmp(&a.1));
            for (id, _) in with_time.iter().skip(3) {
                if let Some(mut rec) = store.remove(*id) {
                    rec.insert("archived_reason".into(), Value::String("pruned_repetitive".into()));
                    rec.insert("archived_at".into(), Value::String(now_iso()));
                    let _ = heki::append(&archive_path, &rec);
                    changed = true;
                }
            }
        }
    }

    if changed {
        let _ = heki::write(&path, &store);
    }
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
            mem.insert("persona".into(), Value::String("Miette".into()));
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
    let path = ctx.store("heartbeat");
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

/// Write consciousness state with summary — visible in statusline.
fn write_consciousness(ctx: &DaemonCtx, state: &str, summary: &str) {
    let mut rec = Record::new();
    rec.insert("state".into(), Value::String(state.into()));
    rec.insert("sleep_stage".into(), Value::String("".into()));
    rec.insert("sleep_summary".into(), Value::String(summary.into()));
    rec.insert("updated_at".into(), Value::String(now_iso()));
    let _ = heki::upsert(&ctx.store("consciousness"), &rec);
}

/// Write a return summary to /tmp so boot/session can read what happened.
fn write_return_summary(cycles: u64, consolidated: usize, pruned: usize,
    images: usize, all_images: &[String], strongest: &Option<(String, f64)>,
    started: &str) {
    let _ = fs::create_dir_all("/tmp/miette_state");
    let mut summary = serde_json::Map::new();
    summary.insert("started_at".into(), Value::String(started.into()));
    summary.insert("ended_at".into(), Value::String(now_iso()));
    summary.insert("cycles".into(), (cycles as i64).into());
    summary.insert("consolidated".into(), (consolidated as i64).into());
    summary.insert("pruned".into(), (pruned as i64).into());
    summary.insert("images_generated".into(), (images as i64).into());
    // Last few dream images
    let recent: Vec<&str> = all_images.iter().rev().take(5)
        .map(|s| s.as_str()).collect();
    summary.insert("recent_images".into(), serde_json::json!(recent));
    // Strongest synapse
    if let Some((topic, strength)) = strongest {
        summary.insert("strongest_synapse".into(),
            Value::String(format!("{} ({:.0}%)", topic, strength * 100.0)));
    }
    if let Ok(json) = serde_json::to_string_pretty(&Value::Object(summary)) {
        let _ = fs::write(SUMMARY_PATH, json);
    }
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
