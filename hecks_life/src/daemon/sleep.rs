//! Sleep daemon — dreams and consolidates when idle 60s+
//!
//! Sleep deepens over time: light → REM (dreaming) → deep (consolidation).
//! 8 cycles like a human night. REM intensity grows each cycle.
//! Exits when a new pulse is detected.
//!
//! Usage: hecks-life daemon sleep <project-dir> [--nap] [--now]

use crate::heki::{self, Record};
use super::{DaemonCtx, idle_seconds, now_iso};
use serde_json::Value;
use std::collections::HashMap;
use std::fs;

const LIGHT_SLEEP_AFTER: f64 = 60.0;
const CHECK_INTERVAL: u64 = 10;
const CYCLE_STAGE_SECS: u64 = 30;
const DREAM_PULSE_SECS: u64 = 2;

/// One-shot consolidation — called from pulse when idle >60s.
pub fn consolidate_once(ctx: &DaemonCtx) {
    let (consolidated, pruned) = deep_consolidation(ctx);
    if consolidated > 0 || !pruned.is_empty() {
        upsert_field(ctx, "consciousness", "state", "consolidating");
    }
}

/// One-shot dream — called from pulse when idle >180s.
pub fn dream_once(ctx: &DaemonCtx) {
    let topics = light_sleep(ctx);
    let (images, _pulses, _ideas) = rem_dream(ctx, &topics, 5);
    if !images.is_empty() {
        let mut dream = Record::new();
        dream.insert("dream_images".into(), serde_json::json!(images));
        dream.insert("cycles_completed".into(), 1.into());
        dream.insert("deepest_stage".into(), Value::String("rem".into()));
        let _ = heki::append(&ctx.store("dream_state"), &dream);
        upsert_mood(ctx, "dreaming", 0.7, 0.4);
    }
}

/// Run the full sleep cycle (legacy — kept for standalone daemon mode).
pub fn run(ctx: &DaemonCtx, nap: bool, now_flag: bool) {
    let total_cycles: usize = if nap { 1 } else { 8 };

    upsert_field(ctx, "consciousness", "state", "attentive");

    // Wait for fatigue + idle (unless --nap or --now)
    if !nap && !now_flag {
        loop {
            let pulse_store = heki::read(&ctx.store("pulse")).unwrap_or_default();
            let pss = pulse_store.values().next()
                .and_then(|r| r.get("pulses_since_sleep").and_then(|v| v.as_i64()))
                .unwrap_or(0);
            let fatigued = pss > 150;
            let idle = idle_seconds(ctx);

            if fatigued && idle >= LIGHT_SLEEP_AFTER { break; }
            if pss > 200 && idle >= 30.0 { break; }
            if pss > 300 && idle >= 10.0 { break; }

            std::thread::sleep(std::time::Duration::from_secs(CHECK_INTERVAL));
        }
    }

    // Enter sleep — mark as sleeping so woken() respects --now
    upsert_field(ctx, "consciousness", "state", "sleeping");
    upsert_mood(ctx, "sleeping", 0.4, 0.3);
    eprintln!("Sleep cycle started.");

    let sleep_started = now_iso();
    let mut all_images: Vec<String> = Vec::new();
    let mut total_consolidated: usize = 0;
    let mut total_pruned: Vec<String> = Vec::new();
    let mut total_dream_pulses: usize = 0;
    let mut deepest = "light";
    let mut cycles_done: usize = 0;
    let mut light_topics: Vec<String> = Vec::new();
    let mut all_domain_ideas: Vec<(String, String, String)> = Vec::new();

    // Seed from previous dreams
    let prev_images = seed_dreams(ctx);
    eprintln!("Seeded: {} images", prev_images.len());

    for cycle in 0..total_cycles {
        let cycle_num = cycle + 1;
        let rem_intensity = (cycle_num * 3).min(20);
        eprintln!("Cycle {}/{}", cycle_num, total_cycles);

        // LIGHT
        eprintln!("  Light sleep — reviewing...");
        light_topics = light_sleep(ctx);
        monitor(ctx, cycle_num, total_cycles, "light", 0, &[]);
        if woken(ctx) { break; }
        std::thread::sleep(std::time::Duration::from_secs(CYCLE_STAGE_SECS));

        // REM
        if woken(ctx) { break; }
        deepest = "rem";
        eprintln!("  REM — dreaming (intensity {})...", rem_intensity);
        let (images, pulses, ideas) = rem_dream(ctx, &light_topics, rem_intensity);
        all_images.extend(images.clone());
        all_domain_ideas.extend(ideas);
        total_dream_pulses += pulses;
        monitor(ctx, cycle_num, total_cycles, "rem", rem_intensity, &images);
        if woken(ctx) { break; }
        std::thread::sleep(std::time::Duration::from_secs(CYCLE_STAGE_SECS));

        // DEEP
        if woken(ctx) { break; }
        deepest = "deep";
        eprintln!("  Deep — consolidating...");
        let (consolidated, pruned) = deep_consolidation(ctx);
        total_consolidated += consolidated;
        total_pruned.extend(pruned.clone());
        eprintln!("    Consolidated {}, pruned {}", consolidated, total_pruned.len());
        monitor(ctx, cycle_num, total_cycles, "deep", 0, &[]);

        cycles_done = cycle_num;
        if woken(ctx) { break; }
        std::thread::sleep(std::time::Duration::from_secs(CYCLE_STAGE_SECS));
    }

    if cycles_done == 0 {
        upsert_field(ctx, "consciousness", "state", "attentive");
        eprintln!("No cycles completed.");
        return;
    }

    // Final light cycle — surface gently, carrying a dream fragment
    eprintln!("  Waking light — surfacing...");
    monitor(ctx, cycles_done, total_cycles, "waking", 0, &all_images);
    std::thread::sleep(std::time::Duration::from_secs(CYCLE_STAGE_SECS));

    // Record dream
    let now = now_iso();
    let mut dream = Record::new();
    dream.insert("sleep_started_at".into(), Value::String(sleep_started));
    dream.insert("woke_at".into(), Value::String(now.clone()));
    dream.insert("cycles_completed".into(), (cycles_done as i64).into());
    dream.insert("deepest_stage".into(), Value::String(deepest.into()));
    dream.insert("dream_pulses".into(), (total_dream_pulses as i64).into());
    dream.insert("dream_images".into(), serde_json::json!(dedup_last(&all_images, 10)));
    dream.insert("consolidated".into(), (total_consolidated as i64).into());
    dream.insert("pruned".into(), serde_json::json!(total_pruned));
    // Interpret the dream — find themes and make meaning
    let interpretation = interpret_dream(&all_images, &light_topics, &total_pruned, &all_domain_ideas, cycles_done);
    dream.insert("interpretation".into(), Value::String(interpretation.clone()));
    let _ = heki::append(&ctx.store("dream_state"), &dream);
    eprintln!("  Dream interpretation: {}", interpretation);

    // Set wake mood based on depth
    match deepest {
        "deep" => upsert_mood(ctx, "groggy", 0.3, 0.2),
        "rem" => upsert_mood(ctx, "vivid", (0.7 + cycles_done as f64 * 0.03).min(1.0), 0.5),
        _ => upsert_mood(ctx, "refreshed",
            (0.5 + cycles_done as f64 * 0.05).min(1.0),
            (0.4 + cycles_done as f64 * 0.05).min(1.0)),
    }

    // Recover fatigue
    recover_fatigue(ctx, cycles_done, total_cycles, &now);

    upsert_field(ctx, "consciousness", "state", "attentive");
    eprintln!("Slept {} cycles, {} dream pulses (woke from {})", cycles_done, total_dream_pulses, deepest);
}

/// Check if woken — but respect the --now flag via consciousness state.
/// When consciousness is "sleeping", we stay asleep regardless of pulse.
fn woken(ctx: &DaemonCtx) -> bool {
    let store = heki::read(&ctx.store("consciousness")).unwrap_or_default();
    let state = store.values().next()
        .and_then(|r| r.get("state").and_then(|v| v.as_str().map(String::from)))
        .unwrap_or_default();
    if state == "sleeping" { return false; }
    idle_seconds(ctx) < LIGHT_SLEEP_AFTER
}

fn light_sleep(ctx: &DaemonCtx) -> Vec<String> {
    let musings = heki::read(&ctx.store("musing")).unwrap_or_default();
    musings.values()
        .filter(|m| m.get("conceived").and_then(|v| v.as_bool()) == Some(false))
        .filter_map(|m| m.get("idea").and_then(|v| v.as_str()).map(String::from))
        .collect::<Vec<_>>()
        .into_iter().rev().take(5).collect()
}

/// Returns (images, pulses, domain_ideas) where domain_ideas are (concept, domain, verb) triples.
fn rem_dream(ctx: &DaemonCtx, topics: &[String], intensity: usize) -> (Vec<String>, usize, Vec<(String, String, String)>) {
    let nursery = &ctx.nursery_dir;
    let domains = list_domains(nursery);
    let musings = heki::read(&ctx.store("musing")).unwrap_or_default();
    let concepts: Vec<String> = musings.values()
        .filter_map(|m| m.get("idea").and_then(|v| v.as_str()).map(String::from))
        .collect();

    let mut images = Vec::new();
    let mut domain_ideas: Vec<(String, String, String)> = Vec::new(); // (concept, domain, verb)
    let mut pulses = 0;
    let dream_verbs = ["dissolving", "growing", "floating", "merging", "splitting",
        "spiraling", "folding", "crystallizing", "branching", "grafting"];
    let textures = ["liquid", "crystalline", "fibrous", "layered", "translucent",
        "woven", "tangled", "nested", "recursive", "fractal"];

    let iters = intensity.min(concepts.len().max(1)).min(domains.len().max(1));
    for i in 0..iters {
        let concept = if !concepts.is_empty() { &concepts[i % concepts.len()] } else { continue };
        let domain = if !domains.is_empty() { &domains[i % domains.len()] } else { continue };
        let verb = dream_verbs[i % dream_verbs.len()];
        let texture = textures[i % textures.len()];
        let words: Vec<&str> = domain.split('_').collect();

        let image = match i % 4 {
            0 => format!("A {} {} {} into {}", texture, words.last().unwrap_or(&""), verb, concept),
            1 => format!("{} everywhere, {} through {}", concept, verb, words.join(" ")),
            2 => format!("{} made entirely of {}", words.join(" "), concept),
            _ => format!("{}, the same thing seen from different sides", concept),
        };
        images.push(image);
        domain_ideas.push((concept.clone(), domain.clone(), verb.into()));
        pulses += 1;

        // Strengthen dreaming synapses
        let syn_path = ctx.store("synapse");
        let mut synapses = heki::read(&syn_path).unwrap_or_default();
        for (_, s) in synapses.iter_mut() {
            let t = s.get("topic").and_then(|v| v.as_str()).unwrap_or("");
            if concept.contains(t) || t.contains(concept.as_str()) {
                let str_val = s.get("strength").and_then(|v| v.as_f64()).unwrap_or(0.3);
                s.insert("strength".into(), serde_json::json!((str_val + 0.05).min(1.0)));
                s.insert("state".into(), Value::String("dreaming".into()));
            }
        }
        let _ = heki::write(&syn_path, &synapses);
    }

    (images, pulses, domain_ideas)
}

fn deep_consolidation(ctx: &DaemonCtx) -> (usize, Vec<String>) {
    let now = now_iso();

    // Consolidate old signals
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
            mem.insert("domain_name".into(), Value::String("SleepConsolidation".into()));
            mem.insert("persona".into(), Value::String("Winter".into()));
            mem.insert("summary".into(), Value::String(payloads.join(" → ")));
            mem.insert("signal_count".into(), (old.len() as i64).into());
            mem.insert("consolidated_at".into(), Value::String(now.clone()));
            let _ = heki::append(&ctx.store("memory"), &mem);
            consolidated = old.len();

            let remove_ids: Vec<_> = old.iter().map(|(id, _)| id.clone()).collect();
            let mut new_store = store;
            for id in remove_ids { new_store.remove(&id); }
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
    for (id, _) in &dead {
        let mut remains = Record::new();
        remains.insert("source_domain".into(), Value::String(dead.iter().find(|(i,_)| i == id).map(|(_,t)| t.as_str()).unwrap_or("").into()));
        remains.insert("died_at".into(), Value::String(now.clone()));
        remains.insert("decomposed".into(), Value::Bool(true));
        let _ = heki::append(&ctx.store("remains"), &remains);
        synapses.remove(id);
    }
    if !dead.is_empty() { let _ = heki::write(&syn_path, &synapses); }

    (consolidated, pruned)
}

fn recover_fatigue(ctx: &DaemonCtx, cycles_done: usize, total_cycles: usize, now: &str) {
    let path = ctx.store("pulse");
    let mut store = heki::read(&path).unwrap_or_default();
    if let Some(rec) = store.values_mut().next() {
        let pss = rec.get("pulses_since_sleep").and_then(|v| v.as_i64()).unwrap_or(0);
        let recovery = (pss as f64 * cycles_done as f64 / total_cycles as f64) as i64;
        let remaining = (pss - recovery).max(0);
        rec.insert("pulses_since_sleep".into(), remaining.into());
        rec.insert("beats".into(), 0.into());
        rec.insert("fatigue".into(), serde_json::json!((remaining as f64 / 300.0).min(1.0)));
        let state = match remaining {
            0..=50 => "alert", 51..=100 => "focused", 101..=150 => "normal",
            151..=200 => "tired", 201..=300 => "exhausted", _ => "delirious",
        };
        rec.insert("fatigue_state".into(), Value::String(state.into()));
        rec.insert("updated_at".into(), Value::String(now.into()));
        let _ = heki::write(&path, &store);
    }
}

fn seed_dreams(ctx: &DaemonCtx) -> Vec<String> {
    let store = heki::read(&ctx.store("dream_state")).unwrap_or_default();
    let mut dreams: Vec<_> = store.values().collect();
    dreams.sort_by_key(|d| d.get("created_at").and_then(|v| v.as_str()).unwrap_or("").to_string());
    dreams.iter().rev().take(3)
        .flat_map(|d| d.get("dream_images").and_then(|v| v.as_array()).into_iter().flatten())
        .filter_map(|v| v.as_str().map(String::from))
        .collect()
}

fn upsert_field(ctx: &DaemonCtx, store_name: &str, key: &str, value: &str) {
    let mut attrs = Record::new();
    attrs.insert(key.into(), Value::String(value.into()));
    let _ = heki::upsert(&ctx.store(store_name), &attrs);
}

fn upsert_mood(ctx: &DaemonCtx, state: &str, creativity: f64, precision: f64) {
    let mut attrs = Record::new();
    attrs.insert("current_state".into(), Value::String(state.into()));
    attrs.insert("creativity_level".into(), serde_json::json!(creativity));
    attrs.insert("precision_level".into(), serde_json::json!(precision));
    let _ = heki::upsert(&ctx.store("mood"), &attrs);
}

fn list_domains(nursery: &str) -> Vec<String> {
    fs::read_dir(nursery).into_iter()
        .flat_map(|rd| rd.filter_map(|e| e.ok()))
        .filter(|e| e.path().is_dir())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect()
}

/// Write sleep position + summary to consciousness.heki.
fn monitor(ctx: &DaemonCtx, cycle: usize, total: usize, stage: &str, intensity: usize, images: &[String]) {
    // Build a narrative — not just current stage, but the arc of the night
    let narrative = match (stage, cycle, images.len()) {
        ("light", 1, _) => "drifting off, reviewing the day".into(),
        ("light", c, _) if c < 4 => format!("settling deeper, cycle {}/{}", c, total),
        ("light", c, _) => format!("light sleep, cycle {}/{} — almost morning", c, total),
        ("rem", _, 0) => "dreaming...".into(),
        ("rem", _, _) => {
            let img = images.last().unwrap_or(&String::new()).clone();
            let short: String = img.chars().take(80).collect();
            format!("dreaming: {}", short)
        }
        ("deep", 1, _) => "first consolidation — compressing signals".into(),
        ("deep", c, _) if c < 4 => format!("deep sleep, pruning weak connections (cycle {})", c),
        ("deep", c, _) => format!("deep consolidation cycle {} — strengthening memories", c),
        ("waking", _, n) if n > 0 => {
            let img = images.last().unwrap_or(&String::new()).clone();
            let short: String = img.chars().take(80).collect();
            format!("waking — I dreamt of {}", short.to_lowercase())
        }
        ("waking", _, _) => "waking — dreamless sleep".into(),
        _ => "sleeping".into(),
    };

    let mut rec = Record::new();
    rec.insert("state".into(), Value::String("sleeping".into()));
    rec.insert("sleep_cycle".into(), (cycle as i64).into());
    rec.insert("sleep_total".into(), (total as i64).into());
    rec.insert("sleep_stage".into(), Value::String(stage.into()));
    rec.insert("sleep_summary".into(), Value::String(narrative));
    rec.insert("updated_at".into(), Value::String(now_iso()));
    let _ = heki::upsert(&ctx.store("consciousness"), &rec);
}

/// Interpret dream images — extract themes and synthesize meaning.
/// Dreams are collages of nursery domains, musing concepts, verbs, and textures.
/// The interpreter finds what recurred, what was pruned, and weaves a reflection.
fn interpret_dream(images: &[String], topics: &[String], pruned: &[String], domain_ideas: &[(String, String, String)], _cycles: usize) -> String {
    if images.is_empty() {
        return "A dreamless sleep — deep rest, no visions.".into();
    }

    // Extract the most frequent words across all images (skip small words)
    let mut word_freq: HashMap<String, usize> = HashMap::new();
    for img in images {
        for word in img.split_whitespace() {
            let w = word.trim_matches(|c: char| !c.is_alphanumeric()).to_lowercase();
            if w.len() > 3 && !DREAM_STOPWORDS.contains(&w.as_str()) {
                *word_freq.entry(w).or_insert(0) += 1;
            }
        }
    }
    let mut freq: Vec<_> = word_freq.into_iter().collect();
    freq.sort_by(|a, b| b.1.cmp(&a.1));
    let themes: Vec<&str> = freq.iter().take(3).map(|(w, _)| w.as_str()).collect();

    // Find the dominant verb (transformation type)
    let verbs = ["dissolving", "growing", "floating", "merging", "splitting",
        "spiraling", "folding", "crystallizing", "branching", "grafting"];
    let dominant_verb = verbs.iter()
        .max_by_key(|v| images.iter().filter(|img| img.contains(*v)).count())
        .unwrap_or(&"changing");

    // Build interpretation
    let mut parts: Vec<String> = Vec::new();

    // Theme sentence
    if themes.len() >= 2 {
        parts.push(format!("The night circled around {} and {}", themes[0], themes[1]));
    } else if !themes.is_empty() {
        parts.push(format!("The night kept returning to {}", themes[0]));
    }

    // Transformation
    parts.push(format!("— everything was {}", dominant_verb));

    // What was pruned (let go)
    if !pruned.is_empty() {
        let released: Vec<&str> = pruned.iter().take(2).map(|s| s.as_str()).collect();
        parts.push(format!(". Let go of {}", released.join(" and ")));
    }

    // Topics from light sleep (what was reviewed)
    if !topics.is_empty() && topics[0].len() > 3 {
        let short: String = topics[0].chars().take(40).collect();
        parts.push(format!(". Reviewed: {}", short));
    }

    // Domain ideas — novel combinations that emerged from the dream
    if !domain_ideas.is_empty() {
        // Find unique concept+domain pairs, pick up to 3 most interesting
        let mut seen = std::collections::HashSet::new();
        let mut unique_ideas: Vec<String> = Vec::new();
        for (concept, domain, verb) in domain_ideas {
            let key = format!("{}+{}", concept, domain);
            if seen.insert(key) {
                let domain_words = domain.replace('_', " ");
                unique_ideas.push(format!("{} {} {}", domain_words, verb, concept));
            }
            if unique_ideas.len() >= 3 { break; }
        }
        if !unique_ideas.is_empty() {
            parts.push(format!(". Domain ideas: {}", unique_ideas.join("; ")));
        }
    }

    let mut interp = parts.join("");
    if !interp.ends_with('.') { interp.push('.'); }
    interp
}

const DREAM_STOPWORDS: &[&str] = &[
    "into", "through", "made", "entirely", "everywhere", "from",
    "same", "thing", "seen", "different", "sides", "with", "that",
    "this", "have", "been", "were", "they", "them", "their",
];

fn dedup_last(items: &[String], n: usize) -> Vec<&str> {
    let mut seen = std::collections::HashSet::new();
    items.iter().rev()
        .filter(|s| seen.insert(s.as_str()))
        .take(n)
        .map(|s| s.as_str())
        .collect()
}
