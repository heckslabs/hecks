//! [antibody-exempt: rust/src/runtime/compute_functions/aggregate_corpus_window.rs —
//!  kernel-surface compute function (i220 sub-gap 5,
//!  compute-adapter-primitive). Reads a named .heki corpus,
//!  filters records by a [lower_bound, upper_bound] timestamp
//!  window, joins the named field across the window into a single
//!  newline-delimited string. Same retirement contract as the
//!  registry parent : retires when the function library becomes
//!  bluebook-driven.]
//!
//! aggregate_corpus_window — generic window-filter-aggregate over any
//! .heki corpus.
//!
//! Replaces the jq pipeline at body/wake_review.sh:51-54 (read
//! dream_state.heki, filter by [sleep_entered_at, woke_at] cycle
//! window, join `dream_images` field per-record into a newline-joined
//! corpus string for the wake-review LLM prompt).
//!
//! The function is generic-enough that any consumer wanting "give me
//! the values of attribute X across records whose timestamp is in
//! window [lo, hi]" can use it ; the caller picks the corpus
//! (`heki:` attr), the field (`field:` attr), the timestamp key
//! (`timestamp_field:` attr — defaults to `updated_at` to match the
//! shell's jq), and the window bounds (`lower_bound:`,
//! `upper_bound:` attrs).
//!
//! Returns the joined corpus as a single string with `\n` between
//! entries (mirrors the shell's `[…] | .[]` jq output piped through
//! variable expansion). Empty string when the corpus is missing,
//! the field is absent across the window, or the window itself is
//! empty.

use crate::heki;
use crate::runtime::AggregateState;
use std::collections::HashMap;

/// Read `<data_dir>/<heki>.heki`, filter records whose
/// `<timestamp_field>` value falls inside `[lower_bound,
/// upper_bound]` (lexicographic ISO-8601 comparison — same as
/// `wake_review.sh`'s jq), and join the values of `<field>` across
/// the matching records with `\n` separators. Returns the joined
/// string, or empty when no records match / the corpus is absent.
///
/// Attrs (with WakeReview-defaulting fallbacks so the function
/// works out-of-the-box for the i220 wake-review use case ; explicit
/// attrs override the defaults for any other consumer) :
///   - `heki`            — corpus name. Defaults to `dream_state`
///                         when absent (WakeReview's corpus).
///   - `field`           — field name to extract from each record.
///                         Defaults to `dream_images` when absent
///                         (WakeReview's per-record content).
///   - `lower_bound`     — inclusive lower bound (ISO-8601 string).
///                         Falls back to `sleep_entered_at` from
///                         attrs (the WakeReview state field name)
///                         when `lower_bound` is absent. Empty when
///                         neither is set.
///   - `upper_bound`     — inclusive upper bound (ISO-8601 string).
///                         Falls back to `woke_at` from attrs when
///                         `upper_bound` is absent. Empty when
///                         neither is set.
///   - `timestamp_field` — record field to compare against the
///                         window (default `updated_at`).
///
/// Returns empty when `data_dir` is None, the bound attrs are
/// missing/empty, the heki file is absent, or no records carry a
/// non-empty value for `field`. The empty-string contract matches
/// the LLM prompt template's tolerance for "no content this cycle".
pub fn aggregate_corpus_window(
    _state: Option<&AggregateState>,
    attrs: &HashMap<String, String>,
    data_dir: Option<&str>,
) -> String {
    let dir = match data_dir {
        Some(d) if !d.is_empty() => d,
        _ => return String::new(),
    };
    let heki_name: &str = attrs.get("heki")
        .map(|s| s.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("dream_state");
    let field: &str = attrs.get("field")
        .map(|s| s.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("dream_images");
    // Bounds : prefer explicit lower_bound / upper_bound ; fall back
    // to WakeReview's state field names so the function plugs into
    // the wake-review chain without any per-dispatch attr massaging.
    let lo: &str = attrs.get("lower_bound")
        .or_else(|| attrs.get("sleep_entered_at"))
        .map(|s| s.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("");
    let hi: &str = attrs.get("upper_bound")
        .or_else(|| attrs.get("woke_at"))
        .map(|s| s.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("");
    if lo.is_empty() || hi.is_empty() { return String::new(); }
    let timestamp_field: &str = attrs.get("timestamp_field")
        .map(|s| s.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("updated_at");

    let path = format!("{}/{}.heki", dir.trim_end_matches('/'), heki_name);
    if !std::path::Path::new(&path).exists() {
        return String::new();
    }
    let store = match heki::read(&path) {
        Ok(s) => s,
        Err(_) => return String::new(),
    };

    // Two-pass : first sort records by the timestamp field so the
    // joined output is stable cycle-over-cycle (heki Store iteration
    // is HashMap-unordered) ; then filter by window and project the
    // field. Sorting before filtering keeps the comparison cost
    // linear — fewer records survive the window.
    let mut rows: Vec<&heki::Record> = store.values().collect();
    rows.sort_by(|a, b| {
        let ka = a.get(timestamp_field).and_then(|v| v.as_str()).unwrap_or("");
        let kb = b.get(timestamp_field).and_then(|v| v.as_str()).unwrap_or("");
        ka.cmp(kb)
    });

    let mut out: Vec<String> = Vec::new();
    for row in rows.iter() {
        let ts = row.get(timestamp_field).and_then(|v| v.as_str()).unwrap_or("");
        if ts < lo || ts > hi { continue; }
        if let Some(val) = row.get(field).and_then(|v| v.as_str()) {
            let trimmed = val.trim();
            if !trimmed.is_empty() {
                out.push(trimmed.to_string());
            }
        }
    }

    out.join("\n")
}
