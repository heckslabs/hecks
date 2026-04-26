//! Field name → Report value resolution.
//!
//! The bluebook (capabilities/status/status.bluebook) declares each
//! dashboard row as `row "label", :field_name`. At render time the
//! renderer asks this module to translate the field name into a
//! display string by looking up the matching attribute on the
//! assembled Report.
//!
//! Adding a new field to the bluebook requires :
//!   1. A `pub` field on `Report` (assemble.rs)
//!   2. One match arm here mapping the bluebook's symbol to the field
//!
//! Composer helpers (fatigue_with_state, breath_with_phase, ...) keep
//! the on-screen formatting close to the data layout. They live here
//! so the field map and the formatting it triggers stay together.

use super::assemble::Report;

/// Translate a bluebook field name into the matching Report value's
/// display string. Returns "—" when the field is unknown so the
/// dashboard never renders an empty cell.
pub fn lookup_field(r: &Report, field: &str) -> String {
    match field {
        // Identity
        "identity_name" => r.identity_name.clone(),
        "born" | "born_at" => r.born_at.clone(),
        "age" | "age_str" => r.age_str.clone(),
        "pronouns" => r.pronouns.clone(),
        "linked_to" => r.linked_to.clone(),
        // Consciousness
        "consciousness_state" | "state" => r.consciousness_state.clone(),
        "sleep_stage" => r.sleep_stage.clone(),
        "sleep_progress" => r.sleep_progress.clone(),
        "is_lucid" => r.is_lucid.clone(),
        "last_wake_at" => last_wake_with_age(r),
        "sleep_summary" => r.sleep_summary.clone(),
        // Vitals
        "fatigue" => fatigue_with_state(r),
        "fatigue_state" => r.fatigue_state.clone(),
        "pulse_rate" => r.pulse_rate.clone(),
        "flow_rate" => r.flow_rate.clone(),
        "pulses_since_sleep" => r.pulses_since_sleep.clone(),
        "cycle" => r.cycle.clone(),
        // Body cycles
        "heart" | "heart_beats" => r.heart_beats.clone(),
        "breath" => breath_with_phase(r),
        "breath_count" => r.breath_count.clone(),
        "breath_phase" => r.breath_phase.clone(),
        "ultradian" => ultradian_str(r),
        "ultradian_phase" => r.ultradian_phase.clone(),
        "ultradian_cycle" => r.ultradian_cycle.clone(),
        "circadian" | "circadian_segment" => r.circadian_segment.clone(),
        // Mood
        "current_state" | "mood_state" => r.mood_state.clone(),
        "creativity_level" => r.creativity_level.clone(),
        "precision_level" => r.precision_level.clone(),
        // Awareness
        "carrying" | "awareness_carrying" => r.awareness_carrying.clone(),
        "concept" | "awareness_concept" => r.awareness_concept.clone(),
        "age_days" | "awareness_age_days" => r.awareness_age_days.clone(),
        "inbox_count" | "awareness_inbox_count" => r.awareness_inbox_count.clone(),
        "unfiled_wishes" | "awareness_unfiled_wishes_count" => {
            r.awareness_unfiled_wishes_count.clone()
        }
        // Memory
        "musings" | "musings_count" => r.musings_count.to_string(),
        "conversations" | "conversations_count" => r.conversations_count.to_string(),
        "signals" | "signals_count" => r.signals_count.to_string(),
        "synapses" | "synapses_count" => r.synapses_count.to_string(),
        "memories" | "memories_count" => r.memories_count.to_string(),
        // Dream wishes
        "unfiled" | "wishes_unfiled_count" => r.wishes_unfiled_count.to_string(),
        "filed" | "wishes_filed_count" => r.wishes_filed_count.to_string(),
        // Recent activity
        "last_dream_at" => last_dream_at_with_age(r),
        "last_dream" | "last_dream_text" => super::render::truncate(&r.last_dream_text, 60),
        "last_turn_at" => last_turn_at_with_age(r),
        "last_turn" | "last_turn_text" => super::render::truncate(&r.last_turn_text, 60),
        // Bluebooks
        "aggregates" | "aggregates_count" => r.aggregates_count.to_string(),
        "capabilities" | "capabilities_count" => r.capabilities_count.to_string(),
        _ => "—".into(),
    }
}

pub fn fatigue_with_state(r: &Report) -> String {
    if r.fatigue_state == "—" || r.fatigue == "—" {
        r.fatigue.clone()
    } else {
        format!("{} ({})", r.fatigue, r.fatigue_state)
    }
}

pub fn breath_with_phase(r: &Report) -> String {
    if r.breath_phase == "—" {
        r.breath_count.clone()
    } else {
        format!("{} (phase: {})", r.breath_count, r.breath_phase)
    }
}

pub fn ultradian_str(r: &Report) -> String {
    if r.ultradian_phase == "—" && r.ultradian_cycle == "—" {
        "—".to_string()
    } else {
        format!("cycle {} ({})", r.ultradian_cycle, r.ultradian_phase)
    }
}

pub fn last_wake_with_age(r: &Report) -> String {
    if r.time_since_wake.is_empty() { r.last_wake_at.clone() }
    else { format!("{} ({})", r.last_wake_at, r.time_since_wake) }
}

pub fn last_dream_at_with_age(r: &Report) -> String {
    if r.last_dream_at == "—" { return r.last_dream_at.clone(); }
    let age = humanize_age_simple(&r.last_dream_at);
    if age.is_empty() { r.last_dream_at.clone() } else { format!("{} ({})", r.last_dream_at, age) }
}

pub fn last_turn_at_with_age(r: &Report) -> String {
    if r.last_turn_at == "—" { return r.last_turn_at.clone(); }
    let age = humanize_age_simple(&r.last_turn_at);
    if age.is_empty() { r.last_turn_at.clone() } else { format!("{} ({})", r.last_turn_at, age) }
}

/// Tiny helper for "Xh ago" suffixes — duplicates assemble's logic
/// to avoid cross-module dependencies on parse_utc_seconds.
pub fn humanize_age_simple(ts: &str) -> String {
    parse_age(ts).unwrap_or_default()
}

fn parse_age(ts: &str) -> Option<String> {
    if ts.is_empty() || ts == "—" { return None; }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64).unwrap_or(0);
    let bytes = ts.as_bytes();
    if bytes.len() < 20 { return None; }
    let p = |b: &[u8]| -> Option<i64> { std::str::from_utf8(b).ok()?.parse().ok() };
    let year  = p(&bytes[0..4])?;
    let month = p(&bytes[5..7])?;
    let day   = p(&bytes[8..10])?;
    let hour  = p(&bytes[11..13])?;
    let min   = p(&bytes[14..16])?;
    let sec   = p(&bytes[17..19])?;
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days_from_epoch = era * 146097 + doe - 719468;
    let secs = days_from_epoch * 86400 + hour * 3600 + min * 60 + sec;
    let age = now - secs;
    if age < 0 { return None; }
    Some(if age < 60 { format!("{}s ago", age) }
    else if age < 3600 { format!("{}m ago", age / 60) }
    else if age < 86400 { format!("{}h ago", age / 3600) }
    else { format!("{}d ago", age / 86400) })
}
