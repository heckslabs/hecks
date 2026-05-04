//! [antibody-exempt: rust/src/runtime/compute_functions/recent_musings.rs —
//!  kernel-surface compute function (i220 sub-gap 5,
//!  compute-adapter-primitive). Reads musing.heki and formats top N
//!  records into a single string for `:compute` adapter consumption.
//!  Same retirement contract as the registry parent : retires when
//!  the function library becomes bluebook-driven.]
//!
//! summarize_recent_musings — read `musing.heki` from `<data_dir>` and
//! format the most recent N musings as a comma-separated string.
//!
//! Used by the i227 MusingMint context-population adapter : the
//! `:mint_idea` LLM prompt template references `{{recent_musings_summary}}`
//! which the existing :llm pipeline can't produce on its own (the
//! musing pool is .heki-resident, not part of any aggregate's state).
//! A `:compute` adapter triggered before the mint dispatch fills the
//! attribute, the LLM hook then sees it as a substituted placeholder.
//!
//! Format : `[ "<idea1>", "<idea2>", … ]` (top 5 by insertion order,
//! most recent last). Empty when `musing.heki` is absent or contains
//! no records — the LLM template tolerates an empty list shape
//! ("don't repeat or paraphrase the following — none yet").
//!
//! N (top count) is currently a constant 5. When future :compute
//! consumers want a different cut, lift it to an `attrs` lookup
//! (`attrs.get("limit")`) ; the current pass keeps the function
//! signature stable across the registry.

use crate::heki;
use crate::runtime::AggregateState;
use std::collections::HashMap;

const DEFAULT_LIMIT: usize = 5;

/// Read `<data_dir>/musing.heki` and format the top `DEFAULT_LIMIT`
/// records' `idea` field into a comma-separated string. Returns
/// the empty string when `data_dir` is None, the file is absent,
/// or no records carry an idea field — the LLM prompt tolerates
/// empty-string substitution as "no recent musings".
pub fn summarize_recent_musings(
    _state: Option<&AggregateState>,
    attrs: &HashMap<String, String>,
    data_dir: Option<&str>,
) -> String {
    let limit: usize = attrs.get("limit")
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(DEFAULT_LIMIT);

    let dir = match data_dir {
        Some(d) if !d.is_empty() => d,
        _ => return String::new(),
    };
    let path = format!("{}/musing.heki", dir.trim_end_matches('/'));
    if !std::path::Path::new(&path).exists() {
        return String::new();
    }
    let store = match heki::read(&path) {
        Ok(s) => s,
        Err(_) => return String::new(),
    };
    // heki::Store is HashMap<String, Record> where Record is
    // HashMap<String, serde_json::Value> ; iteration order is
    // unspecified. Sort by `created_at` (ISO-8601 string sorts
    // chronologically) descending to get most-recent-first, then
    // truncate.
    let mut rows: Vec<&heki::Record> = store.values().collect();
    rows.sort_by(|a, b| {
        let ka = a.get("created_at").and_then(|v| v.as_str()).unwrap_or("");
        let kb = b.get("created_at").and_then(|v| v.as_str()).unwrap_or("");
        kb.cmp(ka)
    });
    let mut out: Vec<String> = Vec::new();
    for row in rows.iter().take(limit) {
        if let Some(idea) = row.get("idea").and_then(|v| v.as_str()) {
            let trimmed = idea.trim();
            if !trimmed.is_empty() {
                out.push(format!("\"{}\"", trimmed.replace('"', "\\\"")));
            }
        }
    }
    if out.is_empty() {
        String::new()
    } else {
        format!("[ {} ]", out.join(", "))
    }
}
