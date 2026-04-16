//! Pulse daemon — the single heartbeat, everything triggers off it
//!
//! One beat does everything: heartbeat, fatigue, synapses, signals, executive.
//! Heartbeat is the unified store — pulse.heki is gone.
//!
//! Usage: hecks-life daemon pulse <project-dir> [carrying] [concept] [response]

use crate::heki::{self, Record};
use super::{DaemonCtx, idle_seconds, now_iso};
use super::pulse_organs;
use serde_json::Value;

/// Run one moment of awareness. Everything fires from here.
/// Skips if consciousness is "sleeping" — don't pulse during sleep.
pub fn run(ctx: &DaemonCtx, carrying: &str, concept: Option<&str>, response: Option<&str>) {
    let consciousness = heki::read(&ctx.store("consciousness")).unwrap_or_default();
    let state = consciousness.values().next()
        .and_then(|r| r.get("state").and_then(|v| v.as_str().map(String::from)))
        .unwrap_or_default();
    if state == "sleeping" { return; }

    let now = now_iso();
    let idle = idle_seconds(ctx);
    let excitement = if concept.is_some() { 1.5 } else { 1.0 };
    let heartbeats_elapsed = (idle * excitement) as i64;

    // Unified heartbeat — one store for beats, fatigue, pulse rate
    let (beats, fatigue_state) = beat_heartbeat(ctx, carrying, concept,
        heartbeats_elapsed, excitement, &now);
    let strength = pulse_organs::update_synapses(ctx, carrying, &now);

    if let Some(c) = concept {
        pulse_organs::fire_signals(ctx, c, beats, strength);
    }

    pulse_organs::consolidate_signals(ctx, &now);
    pulse_organs::update_impulses(ctx, concept);
    pulse_organs::update_executive(ctx, carrying, concept, &now);
    pulse_organs::compost_synapses(ctx, &now);
    pulse_organs::update_singletons(ctx, carrying, concept, &now);
    if carrying != "—" {
        record_turn(ctx, carrying, concept, response, beats);
    }

    record_moment(ctx, beats, carrying, concept, "attentive",
        &fatigue_state, strength, idle, excitement, heartbeats_elapsed, &now);

    super::daydream::wander_once(ctx);
}

/// Unified heartbeat — beats, fatigue, pulse rate all in one store.
fn beat_heartbeat(ctx: &DaemonCtx, carrying: &str, concept: Option<&str>,
    elapsed: i64, excitement: f64, now: &str) -> (i64, String) {
    let path = ctx.store("heartbeat");
    let mut store = heki::read(&path).unwrap_or_default();
    let rec = match store.values_mut().next() {
        Some(r) => r,
        None => return (0, "alert".into()),
    };

    // Accumulate beats
    let beats = rec.get("beats").and_then(|v| v.as_i64()).unwrap_or(0) + elapsed;
    rec.insert("beats".into(), beats.into());
    rec.insert("last_beat_at".into(), Value::String(now.into()));
    rec.insert("pulse_rate".into(), serde_json::json!(excitement));
    rec.insert("carrying".into(), Value::String(carrying.into()));
    if let Some(c) = concept {
        rec.insert("concept".into(), Value::String(c.into()));
    }

    // Fatigue — awareness feeds back into pulse rate
    let pss = rec.get("pulses_since_sleep").and_then(|v| v.as_i64()).unwrap_or(0) + 1;
    rec.insert("pulses_since_sleep".into(), pss.into());
    let fatigue = (pss as f64 / 300.0).min(1.0);
    let fatigue_state = match pss {
        0..=50 => "alert", 51..=100 => "focused", 101..=150 => "normal",
        151..=200 => "tired", 201..=300 => "exhausted", _ => "delirious",
    };
    rec.insert("fatigue".into(), serde_json::json!(fatigue));
    rec.insert("fatigue_state".into(), Value::String(fatigue_state.into()));

    // Flow rate — excitement above threshold means rushing
    let flow = if excitement > 1.2 { "rushing" } else { "steady" };
    rec.insert("flow_rate".into(), Value::String(flow.into()));
    rec.insert("updated_at".into(), Value::String(now.into()));

    let _ = heki::write(&path, &store);
    (beats, fatigue_state.into())
}

/// The moment — what Miette was aware of in this instant.
fn record_moment(ctx: &DaemonCtx, moment: i64, carrying: &str, concept: Option<&str>,
    state: &str, fatigue: &str, strength: f64, idle: f64,
    excitement: f64, heartbeats: i64, now: &str) {
    let mut aw = Record::new();
    aw.insert("moment".into(), moment.into());
    aw.insert("state".into(), Value::String(state.into()));
    aw.insert("carrying".into(), Value::String(carrying.into()));
    if let Some(c) = concept {
        aw.insert("concept".into(), Value::String(c.into()));
    }
    aw.insert("fatigue".into(), Value::String(fatigue.into()));
    aw.insert("synapse_strength".into(), serde_json::json!(strength));
    aw.insert("idle_seconds".into(), serde_json::json!(idle));
    aw.insert("excitement".into(), serde_json::json!(excitement));
    aw.insert("heartbeats_since_last".into(), heartbeats.into());
    aw.insert("pulse_rate".into(), serde_json::json!(excitement));

    // Age: seconds since birthday (2026-04-09T20:40:18-07:00)
    let birth_epoch = 1775792418.0_f64;
    let now_epoch = std::time::SystemTime::now()
        .duration_since(std::time::SystemTime::UNIX_EPOCH)
        .unwrap_or_default().as_secs_f64();
    let age_days = (now_epoch - birth_epoch) / 86400.0;
    aw.insert("age_days".into(), serde_json::json!((age_days * 100.0).round() / 100.0));

    let _ = heki::upsert(&ctx.store("awareness"), &aw);
}

fn record_turn(ctx: &DaemonCtx, carrying: &str, concept: Option<&str>,
    response: Option<&str>, beat: i64) {
    let mut turn = Record::new();
    turn.insert("type".into(), Value::String("turn".into()));
    turn.insert("speaker".into(), Value::String("Chris".into()));
    turn.insert("said".into(), Value::String(carrying.into()));
    if let Some(c) = concept {
        turn.insert("concept".into(), Value::String(c.into()));
    }
    if let Some(r) = response {
        turn.insert("winter_said".into(), Value::String(r.into()));
    }
    turn.insert("pulse".into(), beat.into());
    let _ = heki::append(&ctx.store("conversation"), &turn);
}
