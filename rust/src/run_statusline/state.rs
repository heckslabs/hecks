//! [antibody-exempt: rust/src/run_statusline/ — module of the Statusline
//!  runner ; see mod.rs for the full kernel-floor rationale. Retires
//!  with mod.rs under i78 when the specializer regenerates from a
//!  meta-shape.]
//!
//! Statusline state — all heki sources read up front so render
//! functions stay pure. Reads : consciousness + tick + lucid_dream,
//! plus mood (i640 — Miette's expressive glyph + one-word vibe, set
//! via the bus `MietteBody::Mood.SetMood`, durable in mood.heki).
//! The heartbeat / mint / invention / inbox-heki / claude_assist
//! reads stay dropped with their removed UI.

use std::path::Path;

use crate::heki;

#[derive(Default)]
pub(super) struct State {
    // From consciousness.heki — drives the sleep / awake branch.
    pub(super) consciousness: String,
    pub(super) sleep_summary: String,
    pub(super) sleep_stage: String,
    pub(super) sleep_cycle: i64,
    pub(super) sleep_total: i64,
    pub(super) phase_ticks: i64,
    pub(super) is_lucid: String,
    pub(super) dream_pulses: i64,
    pub(super) dream_pulses_needed: i64,

    // From tick.heki — heartbeat counter ("beats" number).
    pub(super) beats_raw: i64,

    // From lucid_dream.heki (only when lucid REM).
    pub(super) lucid_narrative: String,

    // From mood.heki (i640) — Miette's expressive statusline mood :
    // a free-form glyph + one-word vibe, rendered in front of the
    // heartbeat. Empty when never set ; the segment is then omitted.
    pub(super) mood_glyph: String,
    pub(super) mood_vibe: String,
}

pub(super) fn read_state(info: &Path) -> State {
    let mut s = State::default();
    let info_s = info.to_string_lossy().to_string();

    if let Ok(store) = heki::read(&heki::path_for_lookup(&info_s, "consciousness")) {
        if let Some(rec) = heki::latest(&store) {
            s.consciousness        = string_field(rec, "state");
            s.sleep_summary        = string_field(rec, "sleep_summary");
            s.sleep_stage          = string_field(rec, "sleep_stage");
            s.sleep_cycle          = int_field(rec, "sleep_cycle");
            s.sleep_total          = int_field(rec, "sleep_total");
            s.phase_ticks          = int_field(rec, "phase_ticks");
            s.is_lucid             = string_field(rec, "is_lucid");
            s.dream_pulses         = int_field(rec, "dream_pulses");
            s.dream_pulses_needed  = int_field(rec, "dream_pulses_needed");
            if s.dream_pulses_needed == 0 { s.dream_pulses_needed = 5; }
        }
    }

    if let Ok(store) = heki::read(&heki::path_for_lookup(&info_s, "tick")) {
        if let Some(rec) = heki::latest(&store) {
            s.beats_raw = int_field(rec, "cycle");
        }
    }

    // mood.heki — singleton (PascalCase Mood -> snake_case mood.heki,
    // per the heki adapter). Set through the bus by SetMood ; read
    // here cross-process so the statusline shows how it's going.
    if let Ok(store) = heki::read(&heki::path_for_lookup(&info_s, "mood")) {
        if let Some(rec) = heki::latest(&store) {
            s.mood_glyph = string_field(rec, "glyph");
            s.mood_vibe  = string_field(rec, "vibe");
        }
    }

    if s.is_lucid == "yes" && s.sleep_stage == "rem" {
        if let Ok(store) = heki::read(&heki::path_for_lookup(&info_s, "lucid_dream")) {
            if let Some(rec) = heki::latest(&store) {
                s.lucid_narrative = string_field(rec, "latest_narrative");
            }
        }
    }

    s
}

fn string_field(rec: &heki::Record, key: &str) -> String {
    rec.get(key)
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .unwrap_or_default()
}

fn int_field(rec: &heki::Record, key: &str) -> i64 {
    rec.get(key)
        .and_then(|v| v.as_i64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))
        .unwrap_or(0)
}
