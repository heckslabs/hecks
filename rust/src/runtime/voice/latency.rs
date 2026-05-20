//! [antibody-exempt: rust/src/runtime/voice/latency.rs —
//!  kernel-floor latency capture + rolling-5 ring for Voice.LatencyTelemetry.
//!  Persists through heki::upsert (singleton voice_latency.heki) so the
//!  statusline can read the rolling averages cross-process. Sibling to
//!  phrase_cache.rs ; retires under i557's framework-wide kernel-hook
//!  registry alongside the rest of the :tts wrappers.]
//!
//! Latency telemetry for Voice.Speak
//!
//! `start()` snapshots a monotonic Instant. `record(start, attrs)`
//! computes `total_ms` and `ttfb_ms`, reads the current rolling-5
//! ring out of `voice_latency.heki`, appends the new sample, drops
//! the oldest if the ring exceeds 5, recomputes averages + hit
//! rate, and upserts the singleton back.
//!
//! The ring lives in two pseudo-fields on the singleton :
//! `ring_total_ms` (CSV of last 5 total_ms ints), `ring_hits` (CSV
//! of last 5 cache_hit booleans as "0" / "1"). The bluebook
//! aggregate exposes only the reduced averages + hit_rate_pct ;
//! the CSV ring is an implementation detail of the runtime
//! module, persisted on the same record but not declared on the
//! bluebook surface.

use std::collections::HashMap;
use std::time::Instant;

use crate::heki;

/// A latency measurement window. `start()` captures the monotonic
/// instant just before the HTTP / playback work begins ; `record()`
/// closes it and persists.
pub struct Measurement {
    pub started_at: Instant,
    /// Wall-clock ISO-8601 instant for the event's `ts` field.
    pub ts_iso: String,
}

/// Begin a measurement window. Call this in the dispatcher just
/// before the cache check / HTTP call.
pub fn start() -> Measurement {
    Measurement {
        started_at: Instant::now(),
        ts_iso: now_iso(),
    }
}

/// Record a completed Voice.Speak. `ttfb_ms` is first-token-to-first-sound
/// (for cache hits this equals `total_ms` because playback starts
/// immediately) ; `total_ms` is the full wall-clock from `start()`
/// until the audio stream began. Persists into voice_latency.heki
/// (singleton) under WriteContext::Dispatch tagged with
/// `Voice.Record`.
pub fn record(
    m: &Measurement,
    text_chars: usize,
    ttfb_ms: u128,
    cache_hit: bool,
) {
    let total_ms = m.started_at.elapsed().as_millis();
    let path = latency_heki_path();

    // Read the existing ring (if any).
    let (mut ring_total, mut ring_hits) = read_ring(&path);
    ring_total.push(total_ms as u64);
    ring_hits.push(cache_hit);
    while ring_total.len() > 5 { ring_total.remove(0); }
    while ring_hits.len() > 5 { ring_hits.remove(0); }

    let avg_total = if ring_total.is_empty() {
        0
    } else {
        (ring_total.iter().sum::<u64>() / ring_total.len() as u64) as i64
    };
    let avg_ttfb = ttfb_ms as i64; // last-sample for v1 ; ring grows later
    let hit_rate_pct = if ring_hits.is_empty() {
        0
    } else {
        let h = ring_hits.iter().filter(|b| **b).count() as i64;
        (h * 100) / (ring_hits.len() as i64)
    };

    // Build the singleton record. Pass `id` matching the bluebook's
    // `identified_by :name` default ("voice_latency") so heki::upsert
    // rule 1 (explicit-id update) fires on every call after the first
    // — no reliance on the more fragile singleton-by-count rule 2.
    let mut attrs: HashMap<String, serde_json::Value> = HashMap::new();
    attrs.insert("id".into(), serde_json::Value::String("voice_latency".into()));
    attrs.insert("name".into(), serde_json::Value::String("voice_latency".into()));
    attrs.insert("avg_total_ms".into(), serde_json::Value::from(avg_total));
    attrs.insert("avg_ttfb_ms".into(), serde_json::Value::from(avg_ttfb));
    attrs.insert("sample_count".into(), serde_json::Value::from(ring_total.len() as i64));
    attrs.insert("hit_rate_pct".into(), serde_json::Value::from(hit_rate_pct));
    attrs.insert("last_text_chars".into(), serde_json::Value::from(text_chars as i64));
    attrs.insert("last_cache_hit".into(), serde_json::Value::String(
        if cache_hit { "true".into() } else { "false".into() }
    ));
    attrs.insert("last_ts".into(), serde_json::Value::String(m.ts_iso.clone()));
    attrs.insert("ring_total_ms".into(), serde_json::Value::String(
        ring_total.iter().map(|v| v.to_string()).collect::<Vec<_>>().join(",")
    ));
    attrs.insert("ring_hits".into(), serde_json::Value::String(
        ring_hits.iter().map(|b| if *b { "1" } else { "0" }).collect::<Vec<_>>().join(",")
    ));

    let ctx = heki::WriteContext::Dispatch {
        aggregate: "Voice::LatencyTelemetry",
        command: "Record",
    };
    let _ = heki::upsert(&path, &attrs, ctx);

    // Per-utterance audit log : one append per Voice.Speak with the
    // raw {ts, text_chars, ttfb_ms, total_ms, cache_hit} shape so
    // the audit trail keeps each measurement individually, separate
    // from the rolling singleton above. Mirrors the bluebook's
    // LatencyEvent aggregate (Voice::LatencyEvent.Record emits
    // Latency). The events log lives at voice_latency_events.heki ;
    // best-effort like the singleton write.
    let events_path = events_heki_path();
    let mut event_attrs: HashMap<String, serde_json::Value> = HashMap::new();
    event_attrs.insert("ts".into(), serde_json::Value::String(m.ts_iso.clone()));
    event_attrs.insert("text_chars".into(), serde_json::Value::from(text_chars as i64));
    event_attrs.insert("ttfb_ms".into(), serde_json::Value::from(ttfb_ms as i64));
    event_attrs.insert("total_ms".into(), serde_json::Value::from(total_ms as i64));
    event_attrs.insert("cache_hit".into(), serde_json::Value::String(
        if cache_hit { "true".into() } else { "false".into() }
    ));
    let event_ctx = heki::WriteContext::Dispatch {
        aggregate: "Voice::LatencyEvent",
        command: "Record",
    };
    let _ = heki::append(&events_path, &event_attrs, event_ctx);
}

/// Resolve the latency singleton's heki path under the info dir.
/// Mirrors how mood.heki / drafts.heki are written by sibling
/// dispatchers — info dir → "voice_latency.heki".
fn latency_heki_path() -> String {
    let info = heki::resolve_info_dir();
    let info_s = info.to_string_lossy().to_string();
    heki::path_for_lookup(&info_s, "voice_latency")
}

/// Per-event audit log path. Each Voice.Speak appends one record
/// here ({ts, text_chars, ttfb_ms, total_ms, cache_hit}). Distinct
/// from the rolling singleton so the audit trail survives even if
/// the singleton is overwritten on every dispatch.
fn events_heki_path() -> String {
    let info = heki::resolve_info_dir();
    let info_s = info.to_string_lossy().to_string();
    heki::path_for_lookup(&info_s, "voice_latency_events")
}

/// Read the existing ring CSVs out of the singleton. Returns
/// `(ring_total_ms, ring_hits)` ; both empty on first call / file
/// missing / parse error.
fn read_ring(path: &str) -> (Vec<u64>, Vec<bool>) {
    let store = match heki::read(path) {
        Ok(s) => s,
        Err(_) => return (Vec::new(), Vec::new()),
    };
    let rec = match heki::latest(&store) {
        Some(r) => r,
        None => return (Vec::new(), Vec::new()),
    };
    let totals = rec.get("ring_total_ms")
        .and_then(|v| v.as_str())
        .map(|s| s.split(',').filter_map(|t| t.parse::<u64>().ok()).collect())
        .unwrap_or_default();
    let hits = rec.get("ring_hits")
        .and_then(|v| v.as_str())
        .map(|s| s.split(',').map(|t| t == "1").collect())
        .unwrap_or_default();
    (totals, hits)
}

/// ISO-8601 wall-clock for the event's `ts` field. The runtime's
/// audit log uses the same shape ; we don't reach into storehouse_log
/// to keep the dependency direction clean (runtime/voice doesn't
/// import from storehouse_log).
fn now_iso() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = epoch_to_utc(secs);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, mo, d, h, mi, s)
}

fn epoch_to_utc(secs: u64) -> (i32, u32, u32, u32, u32, u32) {
    let days = (secs / 86_400) as i64;
    let secs_of_day = (secs % 86_400) as u32;
    let h = secs_of_day / 3_600;
    let mi = (secs_of_day % 3_600) / 60;
    let s = secs_of_day % 60;
    let z = days + 719_468;
    let era = if z >= 0 { z / 146_097 } else { (z - 146_096) / 146_097 };
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    let y = (y + if m <= 2 { 1 } else { 0 }) as i32;
    (y, m, d, h, mi, s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn measurement_total_ms_is_monotonic() {
        let m = start();
        std::thread::sleep(std::time::Duration::from_millis(5));
        let elapsed = m.started_at.elapsed().as_millis();
        assert!(elapsed >= 5, "elapsed >= 5ms (got {})", elapsed);
    }

    #[test]
    fn now_iso_shape_is_rfc3339_like() {
        let s = now_iso();
        // YYYY-MM-DDTHH:MM:SSZ → 20 chars
        assert_eq!(s.len(), 20, "iso len: {}", s);
        assert!(s.ends_with('Z'));
        assert_eq!(s.as_bytes()[4], b'-');
        assert_eq!(s.as_bytes()[10], b'T');
    }

    #[test]
    fn read_ring_returns_empty_for_missing_path() {
        let (t, h) = read_ring("/tmp/this_path_does_not_exist_voice_latency.heki");
        assert!(t.is_empty());
        assert!(h.is_empty());
    }
}
