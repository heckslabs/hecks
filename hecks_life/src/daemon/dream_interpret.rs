//! Dream interpretation — extract themes from dreams and propose musings
//!
//! Called after sleep ends or when mindstream returns from idle.
//! Reads dream_state.heki images, finds recurring themes, and
//! mints musings with source "dream" for novel themes.
//!
//! Usage: dream_interpret::interpret_and_propose(&ctx)

use crate::heki::{self, Record};
use super::DaemonCtx;
use serde_json::Value;
use std::collections::HashMap;

const STOPWORDS: &[&str] = &[
    "into", "through", "made", "entirely", "everywhere", "from",
    "same", "thing", "seen", "different", "sides", "with", "that",
    "this", "have", "been", "were", "they", "them", "their",
    "braided", "inside", "where", "meets", "holds", "both",
];

/// Interpret recent dream images and propose musings from recurring themes.
pub fn interpret_and_propose(ctx: &DaemonCtx) -> String {
    let dreams = heki::read(&ctx.store("dream_state")).unwrap_or_default();
    let images: Vec<String> = dreams.values()
        .filter_map(|d| d.get("dream_images").and_then(|v| v.as_array()))
        .flat_map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)))
        .collect();

    if images.is_empty() {
        return "A dreamless sleep — deep rest, no visions.".into();
    }

    let themes = extract_themes(&images);
    let interpretation = synthesize(&themes, images.len());

    // Propose musings from top themes not already in the musing store
    propose_from_themes(ctx, &themes);

    interpretation
}

/// Extract recurring themes by word frequency across all images.
pub fn extract_themes(images: &[String]) -> Vec<(String, usize)> {
    let mut freq: HashMap<String, usize> = HashMap::new();
    for img in images {
        for word in img.split_whitespace() {
            let w = word.trim_matches(|c: char| !c.is_alphanumeric()).to_lowercase();
            if w.len() > 3 && !STOPWORDS.contains(&w.as_str()) {
                *freq.entry(w).or_insert(0) += 1;
            }
        }
    }
    let mut sorted: Vec<_> = freq.into_iter().collect();
    sorted.sort_by(|a, b| b.1.cmp(&a.1));
    sorted.into_iter().take(5).collect()
}

/// Build a one-sentence interpretation from themes.
pub fn synthesize(themes: &[(String, usize)], image_count: usize) -> String {
    let names: Vec<&str> = themes.iter().map(|(w, _)| w.as_str()).collect();
    let mut parts: Vec<String> = Vec::new();

    match names.len() {
        0 => return "A quiet night — drifting without images.".into(),
        1 => parts.push(format!("The night kept returning to {}", names[0])),
        2 => parts.push(format!("The night circled around {} and {}", names[0], names[1])),
        _ => parts.push(format!("The night wove {} and {} and {}", names[0], names[1], names[2])),
    }

    parts.push(format!(" across {} images.", image_count));
    parts.join("")
}

/// Propose musings from dream themes that aren't already in the store.
fn propose_from_themes(ctx: &DaemonCtx, themes: &[(String, usize)]) {
    let musings = heki::read(&ctx.store("musing")).unwrap_or_default();
    let existing: Vec<String> = musings.values()
        .filter_map(|m| m.get("idea").and_then(|v| v.as_str()).map(|s| s.to_lowercase()))
        .collect();

    // Only propose from themes that appeared 3+ times and aren't already musings
    let novel: Vec<&str> = themes.iter()
        .filter(|(_, count)| *count >= 3)
        .filter(|(word, _)| !existing.iter().any(|e| e.contains(word)))
        .map(|(word, _)| word.as_str())
        .take(2)
        .collect();

    if novel.is_empty() { return; }

    // Combine novel themes into one combinatorial musing
    let idea = if novel.len() >= 2 {
        format!("{} and {} — recurring dream theme", novel[0], novel[1])
    } else {
        format!("{} — recurring dream theme", novel[0])
    };

    let mut rec = Record::new();
    rec.insert("idea".into(), Value::String(idea));
    rec.insert("conceived".into(), Value::Bool(false));
    rec.insert("source".into(), Value::String("dream".into()));
    let _ = heki::append(&ctx.store("musing"), &rec);
}
