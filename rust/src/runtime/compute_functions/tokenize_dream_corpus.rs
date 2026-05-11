//! [antibody-exempt: rust/src/runtime/compute_functions/tokenize_dream_corpus.rs —
//!  kernel-surface compute function (i220 sub-gap 6, dream-corpus-tokenize).
//!  Reads dream_state.heki, time-windows the dream images, tokenizes/ranks
//!  them and returns a JSON payload that the DreamInterpretation chain
//!  consumes. Same retirement contract as recent_musings : retires when
//!  the function library becomes bluebook-driven.]
//!
//! tokenize_dream_corpus — read `dream_state.heki` from `<data_dir>`,
//! window the records by `[lower_bound, upper_bound]` (passed via
//! `attrs`), tokenize the dream images, count word frequencies after
//! stopword removal (English + French, mirroring
//! `miette/body/interpret_dream.sh`), and return a serialized JSON
//! payload :
//!
//!   {
//!     "themes":            ["ocean", "dissolving", …],   // top 5
//!     "joined":            "ocean, dissolving, …",       // comma-join
//!     "first_theme":       "ocean",                      // top-1
//!     "themes_above_threshold": ["ocean", "dissolving"]  // count >= 3
//!   }
//!
//! The consumer command stores the JSON string in a single attribute
//! today (then_set has no JSON destructure form ; filed as a follow-on
//! gap). Once a JSON destructure primitive lands, the consumer's
//! then_set chain can extract individual fields without a custom
//! Rust-side parser pass.
//!
//! Used by the i220 retirement of `miette/body/interpret_dream.sh` :
//! the wake event triggers a setup command, this `:compute` adapter
//! resolves the function, and the resulting JSON lands on the
//! DreamInterpretation aggregate where downstream policies pick it up.
//!
//! Window semantics — same as the shell :
//!   - `lower_bound` (ISO-8601) and `upper_bound` (ISO-8601) attrs.
//!   - When BOTH are absent or empty, no time-windowing applies.
//!   - When set, records are kept with `updated_at >= lower` AND
//!     `updated_at <= upper`. ISO-8601 strings sort chronologically
//!     so the comparison is a string compare.
//!
//! Stopword set + JSON serializer live in sibling modules
//! (`dream_corpus_stopwords`, `dream_corpus_json`) to keep this
//! file under the kernel-floor LOC budget.

use crate::heki;
use crate::runtime::AggregateState;
use std::collections::HashMap;

use super::dream_corpus_json::serialize_payload;
use super::dream_corpus_stopwords::is_stopword;

const TOP_N: usize = 5;
const RECURRING_THRESHOLD: usize = 3;

/// Read `<data_dir>/dream_state.heki`, window by `lower_bound` /
/// `upper_bound`, tokenize the dream images, rank, return JSON.
///
/// Returns the empty string when `data_dir` is None, the file is
/// absent, or no records survive the window. The empty string is
/// the contract for "no themes to interpret" — downstream policies
/// can short-circuit by checking for empty.
pub fn tokenize_dream_corpus(
    _state: Option<&AggregateState>,
    attrs: &HashMap<String, String>,
    data_dir: Option<&str>,
) -> String {
    let dir = match data_dir {
        Some(d) if !d.is_empty() => d,
        _ => return String::new(),
    };
    // Match the shell's path resolution : top-level dream_state.heki
    // under the data dir. interpret_dream_smoke.sh seeds the file at
    // exactly this location.
    let path = format!("{}/dream_state.heki", dir.trim_end_matches('/'));
    if !std::path::Path::new(&path).exists() {
        return String::new();
    }
    let store = match heki::read(&path) {
        Ok(s) => s,
        Err(_) => return String::new(),
    };

    let lower = attrs.get("lower_bound").map(|s| s.as_str()).unwrap_or("");
    let upper = attrs.get("upper_bound").map(|s| s.as_str()).unwrap_or("");

    let tokens = collect_tokens(&store, lower, upper);
    if tokens.is_empty() {
        return String::new();
    }
    let ranked = rank_by_count(tokens);
    let top: Vec<&(String, usize)> = ranked.iter().take(TOP_N).collect();
    let themes: Vec<String> = top.iter().map(|(w, _)| w.clone()).collect();
    let joined = themes.join(", ");
    let first_theme = themes.first().cloned().unwrap_or_default();
    let above: Vec<String> = top.iter()
        .filter(|(_, c)| *c >= RECURRING_THRESHOLD)
        .map(|(w, _)| w.clone())
        .collect();

    serialize_payload(&themes, &joined, &first_theme, &above)
}

/// Walk the store, window each record, flatten + tokenize the
/// `dream_images` field. Out-of-window records are silently skipped.
fn collect_tokens(store: &heki::Store, lower: &str, upper: &str) -> Vec<String> {
    let mut tokens: Vec<String> = Vec::new();
    for record in store.values() {
        if !record_in_window(record, lower, upper) {
            continue;
        }
        for img in extract_dream_images(record) {
            for tok in tokenize(&img) {
                tokens.push(tok);
            }
        }
    }
    tokens
}

/// Group tokens by value and sort by `(count desc, word asc)` —
/// same secondary key the jq pipeline uses
/// (`sort_by(-.count, .word)`).
fn rank_by_count(tokens: Vec<String>) -> Vec<(String, usize)> {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for tok in tokens {
        *counts.entry(tok).or_insert(0) += 1;
    }
    let mut ranked: Vec<(String, usize)> = counts.into_iter().collect();
    ranked.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    ranked
}

/// True when the record's `updated_at` (or `created_at` fallback)
/// sits inside `[lower, upper]`. Empty bounds mean "no constraint
/// on that side".
fn record_in_window(record: &heki::Record, lower: &str, upper: &str) -> bool {
    if lower.is_empty() && upper.is_empty() {
        return true;
    }
    let ts = record_timestamp(record);
    if !lower.is_empty() && ts.as_str() < lower {
        return false;
    }
    if !upper.is_empty() && ts.as_str() > upper {
        return false;
    }
    true
}

/// Pick the record's timestamp — `updated_at` if present, else
/// `created_at`, else empty string (which fails any non-empty bound).
fn record_timestamp(record: &heki::Record) -> String {
    if let Some(v) = record.get("updated_at").and_then(|v| v.as_str()) {
        return v.to_string();
    }
    if let Some(v) = record.get("created_at").and_then(|v| v.as_str()) {
        return v.to_string();
    }
    String::new()
}

/// Pull `dream_images` out of a record. Tolerates both the array
/// shape (canonical JSON form) and the comma-joined string shape
/// (what `storehouse heki append … dream_images=foo` writes for a
/// single-string attribute).
fn extract_dream_images(record: &heki::Record) -> Vec<String> {
    let v = match record.get("dream_images") {
        Some(v) => v,
        None => return Vec::new(),
    };
    if let Some(arr) = v.as_array() {
        return arr.iter()
            .filter_map(|item| item.as_str().map(|s| s.to_string()))
            .collect();
    }
    if let Some(s) = v.as_str() {
        return vec![s.to_string()];
    }
    Vec::new()
}

/// Lowercase + extract `[a-z]+` runs of length >= 3, drop stopwords.
/// Mirrors the jq `ascii_downcase | scan("[a-z]+") | select(length>=3)
/// | select(stopwords | not)` chain.
fn tokenize(text: &str) -> Vec<String> {
    let lower = text.to_ascii_lowercase();
    let mut out: Vec<String> = Vec::new();
    let mut current = String::new();
    for ch in lower.chars() {
        if ch.is_ascii_lowercase() {
            current.push(ch);
        } else if !current.is_empty() {
            push_if_keepable(&mut out, &current);
            current.clear();
        }
    }
    if !current.is_empty() {
        push_if_keepable(&mut out, &current);
    }
    out
}

fn push_if_keepable(out: &mut Vec<String>, candidate: &str) {
    if candidate.len() < 3 || is_stopword(candidate) {
        return;
    }
    out.push(candidate.to_string());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokenize_drops_stopwords_and_short_words() {
        let toks = tokenize("the ocean dissolving in a library");
        assert_eq!(toks, vec!["ocean", "dissolving", "library"]);
    }

    #[test]
    fn tokenize_handles_french_stopwords() {
        let toks = tokenize("je suis dans le monde");
        assert_eq!(toks, vec!["monde"]);
    }

    #[test]
    fn empty_data_dir_returns_empty_string() {
        let attrs = HashMap::new();
        assert_eq!(tokenize_dream_corpus(None, &attrs, None), "");
    }

    #[test]
    fn missing_dream_state_heki_returns_empty_string() {
        let attrs = HashMap::new();
        let tmp = std::env::temp_dir().join("tokenize_dream_corpus_missing");
        let _ = std::fs::create_dir_all(&tmp);
        assert_eq!(tokenize_dream_corpus(None, &attrs, tmp.to_str()), "");
    }

    #[test]
    fn record_window_open_bounds_admits_everything() {
        let mut r: heki::Record = HashMap::new();
        r.insert("updated_at".into(), serde_json::json!("2026-05-03T00:00:00Z"));
        assert!(record_in_window(&r, "", ""));
    }

    #[test]
    fn record_window_lower_bound_rejects_older() {
        let mut r: heki::Record = HashMap::new();
        r.insert("updated_at".into(), serde_json::json!("2026-05-01T00:00:00Z"));
        assert!(!record_in_window(&r, "2026-05-02T00:00:00Z", ""));
    }

    #[test]
    fn record_window_upper_bound_rejects_newer() {
        let mut r: heki::Record = HashMap::new();
        r.insert("updated_at".into(), serde_json::json!("2026-05-05T00:00:00Z"));
        assert!(!record_in_window(&r, "", "2026-05-04T00:00:00Z"));
    }

    #[test]
    fn extract_dream_images_array_form() {
        let mut r: heki::Record = HashMap::new();
        r.insert("dream_images".into(), serde_json::json!(["a", "b"]));
        assert_eq!(extract_dream_images(&r), vec!["a", "b"]);
    }

    #[test]
    fn extract_dream_images_string_form() {
        let mut r: heki::Record = HashMap::new();
        r.insert("dream_images".into(), serde_json::json!("a single image"));
        assert_eq!(extract_dream_images(&r), vec!["a single image"]);
    }
}
