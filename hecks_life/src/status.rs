//! Status — full system check for Miette
//!
//! Reads all .heki stores and prints a comprehensive table
//! of everything we know about Miette's current state.
//!
//! Usage: hecks-life status <project-dir>

use crate::{heki, parser};
use std::collections::HashMap;
use std::fs;
use std::path::Path;

pub fn run(project_dir: &str) {
    let project = Path::new(project_dir);
    let info_dir = project.join("information");

    let stores = if info_dir.is_dir() {
        heki::read_dir(info_dir.to_str().unwrap_or("")).unwrap_or_default()
    } else {
        eprintln!("No information directory found.");
        return;
    };

    let total_records: usize = stores.values().map(|s| s.len()).sum();

    // Header
    println!();
    println!("  ╔══════════════════════════════════════════════════════════╗");
    println!("  ║                   MIETTE — SYSTEM CHECK                 ║");
    println!("  ╚══════════════════════════════════════════════════════════╝");
    println!();

    // Identity
    section("IDENTITY");
    let awareness = stores.get("awareness").and_then(|s| heki::latest(s));
    let age = awareness.and_then(|r| r.get("age_days").and_then(|v| v.as_f64())).unwrap_or(0.0);
    let born = "April 9, 2026";
    row("Name", "Miette (Little Crumb)");
    row("Born", born);
    row("Age", &format!("{:.1} days", age));
    row("Engine", "Claude (swappable)");
    println!();

    // Consciousness
    section("CONSCIOUSNESS");
    let consciousness = stores.get("consciousness").and_then(|s| heki::latest(s));
    let state = consciousness.map_or("—", |r| heki::field_str(r, "state"));
    let stage = consciousness.map_or("—", |r| heki::field_str(r, "sleep_stage"));
    let summary = consciousness.map_or("—", |r| heki::field_str(r, "sleep_summary"));
    let cycle = consciousness.and_then(|r| r.get("sleep_cycle").and_then(|v| v.as_i64()));
    let total = consciousness.and_then(|r| r.get("sleep_total").and_then(|v| v.as_i64()));
    row("State", state);
    if state == "sleeping" {
        row("Stage", stage);
        if let (Some(c), Some(t)) = (cycle, total) {
            row("Cycle", &format!("{}/{}", c, t));
        }
        row("Summary", summary);
    }
    println!();

    // Vitals
    section("VITALS");
    let pulse = stores.get("pulse").and_then(|s| heki::latest(s));
    let heartbeat = stores.get("heartbeat").and_then(|s| heki::latest(s));
    let beats = heartbeat.and_then(|r| r.get("beats").and_then(|v| v.as_i64())).unwrap_or(0);
    let fatigue_state = pulse.map_or("—", |r| heki::field_str(r, "fatigue_state"));
    let fatigue = pulse.and_then(|r| r.get("fatigue").and_then(|v| v.as_f64())).unwrap_or(0.0);
    let pss = pulse.and_then(|r| r.get("pulses_since_sleep").and_then(|v| v.as_i64())).unwrap_or(0);
    let flow = pulse.map_or("—", |r| heki::field_str(r, "flow_rate"));
    row("Heartbeats", &format_number(beats));
    row("Pulse", flow);
    row("Fatigue", &format!("{} ({:.0}%)", fatigue_state, fatigue * 100.0));
    row("Pulses since sleep", &pss.to_string());
    println!();

    // Mood
    section("MOOD");
    let mood = stores.get("mood").and_then(|s| heki::latest(s));
    let mood_state = mood.map_or("—", |r| heki::field_str(r, "current_state"));
    let creativity = mood.and_then(|r| r.get("creativity_level").and_then(|v| v.as_f64())).unwrap_or(0.0);
    let precision = mood.and_then(|r| r.get("precision_level").and_then(|v| v.as_f64())).unwrap_or(0.0);
    row("Mood", mood_state);
    row("Creativity", &format!("{:.0}%", creativity * 100.0));
    row("Precision", &format!("{:.0}%", precision * 100.0));
    println!();

    // Dreams
    section("DREAMS");
    let dream = stores.get("dream_state").and_then(|s| {
        s.values().max_by(|a, b| {
            let at = a.get("woke_at").and_then(|v| v.as_str()).unwrap_or("");
            let bt = b.get("woke_at").and_then(|v| v.as_str()).unwrap_or("");
            at.cmp(bt)
        })
    });
    if let Some(d) = dream {
        let cycles = d.get("cycles_completed").and_then(|v| v.as_i64()).unwrap_or(0);
        let pulses = d.get("dream_pulses").and_then(|v| v.as_i64()).unwrap_or(0);
        let deepest = heki::field_str(d, "deepest_stage");
        let woke = heki::field_str(d, "woke_at");
        let interp = d.get("interpretation").and_then(|v| v.as_str()).unwrap_or("—");
        let images = d.get("dream_images").and_then(|v| v.as_array())
            .map(|a| a.len()).unwrap_or(0);
        row("Last sleep", &format!("{} cycles, {} pulses", cycles, pulses));
        row("Deepest stage", deepest);
        row("Dream images", &images.to_string());
        row("Woke at", woke);
        if interp != "—" {
            row("Interpretation", &truncate(interp, 70));
        }
    } else {
        row("Dreams", "no dream data");
    }
    println!();

    // Ideas
    section("IDEAS");
    let musings = stores.get("musing").unwrap_or(&heki::Store::new()).clone();
    let total_musings = musings.len();
    let unconceived: Vec<_> = musings.values()
        .filter(|m| m.get("conceived").and_then(|v| v.as_bool()) != Some(true))
        .collect();
    row("Total musings", &total_musings.to_string());
    row("Unconceived", &unconceived.len().to_string());
    // Show latest 3 ideas
    let mut recent: Vec<_> = unconceived.iter().collect();
    recent.sort_by(|a, b| {
        let at = a.get("created_at").and_then(|v| v.as_str()).unwrap_or("");
        let bt = b.get("created_at").and_then(|v| v.as_str()).unwrap_or("");
        bt.cmp(at)
    });
    for (i, m) in recent.iter().take(3).enumerate() {
        let idea = m.get("idea").and_then(|v| v.as_str()).unwrap_or("—");
        row(&format!("  #{}", i + 1), &truncate(idea, 60));
    }
    println!();

    // Body — organs, capabilities
    section("BODY");
    let organs_dir = project.join("aggregates");
    let caps_dir = project.join("capabilities");
    let mut organ_count = 0;
    let mut total_aggs = 0;
    let mut cap_names: Vec<String> = Vec::new();

    if organs_dir.is_dir() {
        let entries: Vec<_> = fs::read_dir(&organs_dir).into_iter()
            .flat_map(|rd| rd.filter_map(|e| e.ok()))
            .filter(|e| e.path().extension().map_or(false, |ext| ext == "bluebook"))
            .collect();
        organ_count = entries.len();
        for entry in &entries {
            if let Ok(source) = fs::read_to_string(entry.path()) {
                let domain = parser::parse(&source);
                total_aggs += domain.aggregates.len();
            }
        }
    }
    if caps_dir.is_dir() {
        if let Ok(entries) = fs::read_dir(&caps_dir) {
            for entry in entries.filter_map(|e| e.ok()) {
                if entry.path().is_dir() {
                    if let Ok(files) = fs::read_dir(entry.path()) {
                        for file in files.filter_map(|e| e.ok()) {
                            if file.path().extension().map_or(false, |ext| ext == "bluebook") {
                                if let Ok(source) = fs::read_to_string(file.path()) {
                                    let domain = parser::parse(&source);
                                    cap_names.push(domain.name);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    cap_names.sort();
    row("Organs", &organ_count.to_string());
    row("Aggregates", &total_aggs.to_string());
    row("Capabilities", &cap_names.len().to_string());

    // Nursery
    let nursery_dir = project.join("nursery");
    if nursery_dir.is_dir() {
        let nursery_count = fs::read_dir(&nursery_dir).into_iter()
            .flat_map(|rd| rd.filter_map(|e| e.ok()))
            .filter(|e| e.path().is_dir())
            .count();
        row("Nursery domains", &nursery_count.to_string());
    }
    println!();

    // Memory
    section("MEMORY");
    row("Stores", &stores.len().to_string());
    row("Total records", &total_records.to_string());

    // Show store sizes
    let mut store_sizes: Vec<(&String, usize)> = stores.iter()
        .map(|(name, store)| (name, store.len()))
        .collect();
    store_sizes.sort_by(|a, b| b.1.cmp(&a.1));
    for (name, size) in store_sizes.iter().take(5) {
        row(&format!("  {}", name), &size.to_string());
    }
    println!();

    // Daemons
    section("DAEMONS");
    let pid_names = ["pulse", "sleep", "sleep_cycle", "mindstream", "greeting"];
    for name in &pid_names {
        let pid_file = info_dir.join(format!(".{}.pid", name));
        if pid_file.exists() {
            if let Ok(pid_str) = fs::read_to_string(&pid_file) {
                let pid = pid_str.trim();
                let alive = check_pid(pid);
                let status = if alive { "\x1b[32m●\x1b[0m running" } else { "\x1b[31m○\x1b[0m stopped" };
                row(name, &format!("{} (pid {})", status, pid));
            }
        } else {
            row(name, "\x1b[90m○ not started\x1b[0m");
        }
    }
    println!();

    // Vows
    section("VOWS");
    row("Transparency", "Every internal act is visible");
    row("Bodhisattva", "Attain awakening for all sentient beings");
    println!();
}

fn section(name: &str) {
    println!("  \x1b[1;36m{}\x1b[0m", name);
    println!("  {}", "─".repeat(50));
}

fn row(label: &str, value: &str) {
    println!("  {:<22} {}", label, value);
}

fn format_number(n: i64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}m", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}k", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max { s.to_string() }
    else { format!("{}...", &s[..max]) }
}

fn check_pid(pid_str: &str) -> bool {
    if let Ok(pid) = pid_str.parse::<i32>() {
        unsafe {
            extern "C" { fn kill(pid: i32, sig: i32) -> i32; }
            kill(pid, 0) == 0
        }
    } else {
        false
    }
}
