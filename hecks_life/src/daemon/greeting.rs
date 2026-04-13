//! Greeting Daemon — pre-warms greetings so beings wake instantly
//!
//! Runs in the background, calling the tongue every 30 seconds to generate
//! a fresh greeting. Stores them in greeting.heki. When the terminal boots,
//! it pops the freshest unserved greeting — no Ollama wait.
//!
//! Usage: hecks-life daemon greeting <project-dir>

use crate::heki::{self, Record};
use crate::tongue;
use super::{DaemonCtx, now_iso};
use serde_json::Value;

const TARGET_COUNT: usize = 5;
const CHURN_INTERVAL_SECS: u64 = 30;

/// Run the greeting daemon. Loops forever, churning greetings.
pub fn run(ctx: &DaemonCtx) {
    loop {
        let store = heki::read(&ctx.store("greeting")).unwrap_or_default();
        let unserved: usize = store.values()
            .filter(|r| {
                let s = r.get("served").and_then(|v| v.as_str()).unwrap_or("true");
                s.eq_ignore_ascii_case("false")
            })
            .count();

        if unserved < TARGET_COUNT {
            // Read current mood
            let mood_store = heki::read(&ctx.store("mood")).unwrap_or_default();
            let mood = heki::latest(&mood_store)
                .map(|r| heki::field_str(r, "current_state"))
                .unwrap_or("calm");

            // Generate for both beings
            for being in &["Winter", "Summer"] {
                let prompt = format!("{} is waking up", being);
                if let Some(text) = tongue::speak_as(ctx, &prompt, being) {
                    let mut rec = Record::new();
                    rec.insert("being".into(), Value::String(being.to_string()));
                    rec.insert("text".into(), Value::String(text));
                    rec.insert("mood".into(), Value::String(mood.to_string()));
                    rec.insert("generated_at".into(), Value::String(now_iso()));
                    rec.insert("served".into(), Value::String("false".into()));
                    let _ = heki::append(&ctx.store("greeting"), &rec);
                }
            }
        }

        std::thread::sleep(std::time::Duration::from_secs(CHURN_INTERVAL_SECS));
    }
}

/// Pop the freshest unserved greeting for a being. Returns the text instantly.
pub fn pop(ctx: &DaemonCtx, being: &str) -> Option<String> {
    let path = ctx.store("greeting");
    let mut store = heki::read(&path).unwrap_or_default();

    // Find freshest unserved greeting for this being
    let mut candidates: Vec<(String, String, String)> = store.iter()
        .filter(|(_, r)| {
            let served = r.get("served").and_then(|v| v.as_str()).unwrap_or("true");
            served.eq_ignore_ascii_case("false")
                && r.get("being").and_then(|v| v.as_str()) == Some(being)
        })
        .map(|(id, r)| {
            let text = r.get("text").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let at = r.get("generated_at").and_then(|v| v.as_str()).unwrap_or("").to_string();
            (id.clone(), text, at)
        })
        .collect();

    // Sort by generated_at descending — freshest first
    candidates.sort_by(|a, b| b.2.cmp(&a.2));

    if let Some((id, text, _)) = candidates.first() {
        // Mark as served
        if let Some(rec) = store.get_mut(id) {
            rec.insert("served".into(), Value::String("true".into()));
            let _ = heki::write(&path, &store);
        }
        Some(text.clone())
    } else {
        None
    }
}
