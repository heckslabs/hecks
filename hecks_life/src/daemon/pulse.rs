//! Pulse daemon — the single heartbeat, everything triggers off it
//!
//! One beat does everything based on idle time:
//!   Active:     pulse, heartbeat, fatigue, synapses, signals, executive
//!   Idle >10s:  + daydream (wander across nursery, free-associate)
//!   Idle >60s:  + consolidate (compress signals into memories)
//!   Idle >180s: + dream (recombine concepts, generate images, prune)
//!
//! Usage: hecks-life daemon pulse <project-dir> [carrying] [concept] [response]

use crate::heki::{self, Record};
use super::{DaemonCtx, idle_seconds, now_iso};
use serde_json::Value;

/// Run one moment of awareness. Everything fires from here.
/// Skips if consciousness is "sleeping" — don't pulse during sleep.
pub fn run(ctx: &DaemonCtx, carrying: &str, concept: Option<&str>, response: Option<&str>) {
    // Don't pulse during sleep — it wakes the dreamer
    let consciousness = heki::read(&ctx.store("consciousness")).unwrap_or_default();
    let state = consciousness.values().next()
        .and_then(|r| r.get("state").and_then(|v| v.as_str().map(String::from)))
        .unwrap_or_default();
    if state == "sleeping" { return; }

    let now = now_iso();
    let idle = idle_seconds(ctx);

    // Heartbeat: 1 beat/sec baseline, excitement raises it
    // Calculate beats elapsed since last moment
    let excitement = if concept.is_some() { 1.5 } else { 1.0 };
    let heartbeats_elapsed = (idle * excitement) as i64;

    // Always: core vitals
    let (moment_num, _) = beat_pulse(ctx, carrying, concept, &now);
    accumulate_heartbeats(ctx, heartbeats_elapsed, excitement, &now);
    let fatigue_state = update_fatigue(ctx, &now);
    let strength = update_synapses(ctx, carrying, &now);

    if let Some(c) = concept {
        fire_signals(ctx, c, moment_num, strength);
    }

    // Always: executive + singletons + conversation
    consolidate_signals(ctx, &now);
    update_impulses(ctx, concept);
    update_executive(ctx, carrying, concept, &now);
    compost_synapses(ctx, &now);
    update_singletons(ctx, carrying, concept, &now);
    if carrying != "—" {
        record_turn(ctx, carrying, concept, response, moment_num);
    }

    // Record the moment of awareness — the full snapshot of this instant
    record_moment(ctx, moment_num, carrying, concept, "attentive",
        &fatigue_state, strength, idle, excitement, heartbeats_elapsed, &now);

    // One daydream wander per moment
    super::daydream::wander_once(ctx);
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
    let age_secs = now_epoch - birth_epoch;
    let age_days = age_secs / 86400.0;
    aw.insert("age_days".into(), serde_json::json!((age_days * 100.0).round() / 100.0));

    let _ = heki::upsert(&ctx.store("awareness"), &aw);
}

fn beat_pulse(ctx: &DaemonCtx, carrying: &str, concept: Option<&str>, now: &str) -> (i64, f64) {
    let path = ctx.store("pulse");
    let mut store = heki::read(&path).unwrap_or_default();
    let rec = match store.values_mut().next() {
        Some(r) => r,
        None => { eprintln!("No pulse record"); return (0, 0.0); }
    };
    let beats = rec.get("beats").and_then(|v| v.as_i64()).unwrap_or(0) + 1;
    rec.insert("beats".into(), beats.into());
    rec.insert("carrying".into(), Value::String(carrying.into()));
    let pss = rec.get("pulses_since_sleep").and_then(|v| v.as_i64()).unwrap_or(0) + 1;
    rec.insert("pulses_since_sleep".into(), pss.into());
    if let Some(c) = concept {
        rec.insert("concept".into(), Value::String(c.into()));
    }
    rec.insert("updated_at".into(), Value::String(now.into()));
    let _ = heki::write(&path, &store);
    (beats, 0.3)
}

/// Heartbeat: accumulate elapsed beats (1/sec baseline × excitement).
fn accumulate_heartbeats(ctx: &DaemonCtx, elapsed: i64, excitement: f64, now: &str) {
    let path = ctx.store("heartbeat");
    let mut store = heki::read(&path).unwrap_or_default();
    if let Some(rec) = store.values_mut().next() {
        let beats = rec.get("beats").and_then(|v| v.as_i64()).unwrap_or(0) + elapsed;
        rec.insert("beats".into(), beats.into());
        rec.insert("last_beat_at".into(), Value::String(now.into()));
        rec.insert("pulse_rate".into(), serde_json::json!(excitement));
        rec.insert("updated_at".into(), Value::String(now.into()));
        let _ = heki::write(&path, &store);
    }
}

fn update_fatigue(ctx: &DaemonCtx, now: &str) -> String {
    let path = ctx.store("pulse");
    let mut store = heki::read(&path).unwrap_or_default();
    let rec = match store.values_mut().next() {
        Some(r) => r,
        None => return "alert".into(),
    };
    let pss = rec.get("pulses_since_sleep").and_then(|v| v.as_i64()).unwrap_or(0);
    let fatigue = (pss as f64 / 300.0).min(1.0);
    let state = match pss {
        0..=50 => "alert", 51..=100 => "focused", 101..=150 => "normal",
        151..=200 => "tired", 201..=300 => "exhausted", _ => "delirious",
    };
    rec.insert("fatigue".into(), serde_json::json!(fatigue));
    rec.insert("fatigue_state".into(), Value::String(state.into()));
    rec.insert("updated_at".into(), Value::String(now.into()));
    let _ = heki::write(&path, &store);
    state.into()
}

fn update_synapses(ctx: &DaemonCtx, carrying: &str, now: &str) -> f64 {
    let path = ctx.store("synapse");
    let mut store = heki::read(&path).unwrap_or_default();
    let existing_id = store.iter()
        .find(|(_, s)| s.get("topic").and_then(|v| v.as_str()) == Some(carrying))
        .map(|(id, _)| id.clone());

    let strength = if let Some(id) = existing_id {
        let s = store.get_mut(&id).unwrap();
        let firings = s.get("firings").and_then(|v| v.as_i64()).unwrap_or(0) + 1;
        let str_val = (s.get("strength").and_then(|v| v.as_f64()).unwrap_or(0.3) + 0.1).min(1.0);
        s.insert("firings".into(), firings.into());
        s.insert("strength".into(), serde_json::json!(str_val));
        s.insert("last_fired_at".into(), Value::String(now.into()));
        s.insert("potentiated".into(), Value::Bool(str_val >= 0.7));
        s.insert("state".into(), Value::String(
            if str_val >= 0.7 { "potentiated" } else { "active" }.into()));
        s.insert("updated_at".into(), Value::String(now.into()));
        str_val
    } else {
        let id = heki::uuid_v4();
        let mut rec = Record::new();
        rec.insert("id".into(), Value::String(id.clone()));
        rec.insert("topic".into(), Value::String(carrying.into()));
        rec.insert("strength".into(), serde_json::json!(0.3));
        rec.insert("firings".into(), 1.into());
        rec.insert("last_fired_at".into(), Value::String(now.into()));
        rec.insert("potentiated".into(), Value::Bool(false));
        rec.insert("state".into(), Value::String("forming".into()));
        rec.insert("created_at".into(), Value::String(now.into()));
        rec.insert("updated_at".into(), Value::String(now.into()));
        store.insert(id, rec);
        0.3
    };
    let _ = heki::write(&path, &store);
    strength
}

fn fire_signals(ctx: &DaemonCtx, concept: &str, beat: i64, strength: f64) {
    let mut somatic = Record::new();
    somatic.insert("source_layer".into(), Value::String("OrganMap".into()));
    somatic.insert("hemisphere".into(), Value::String("feeling".into()));
    somatic.insert("activation".into(), serde_json::json!(0.4));
    somatic.insert("valence".into(), serde_json::json!(if strength >= 0.5 { 0.6 } else { 0.2 }));
    somatic.insert("tag".into(), Value::String("somatic".into()));
    somatic.insert("payload".into(), Value::String(format!("strength:{:.1}", strength)));
    somatic.insert("beat".into(), beat.into());
    let _ = heki::upsert(&ctx.store("signal_somatic"), &somatic);

    let mut sig = Record::new();
    sig.insert("source_layer".into(), Value::String("PatternEngine".into()));
    sig.insert("hemisphere".into(), Value::String("thinking".into()));
    sig.insert("activation".into(), serde_json::json!(0.7));
    sig.insert("valence".into(), serde_json::json!(0.5));
    sig.insert("tag".into(), Value::String("concept".into()));
    sig.insert("payload".into(), Value::String(concept.into()));
    let _ = heki::append(&ctx.store("signal"), &sig);

    // Concepts go to signals, not musings. Musings come from the mindstream
    // (concept+domain collisions) or deliberate session ideas — not every pulse.
}

fn consolidate_signals(ctx: &DaemonCtx, now: &str) {
    let path = ctx.store("signal");
    let store = heki::read(&path).unwrap_or_default();
    if store.len() <= 20 { return; }

    let mut sorted: Vec<_> = store.iter().collect();
    sorted.sort_by_key(|(_, s)| s.get("created_at").and_then(|v| v.as_str()).unwrap_or("").to_string());

    let old: Vec<_> = sorted[..sorted.len() - 20].iter()
        .filter(|(_, s)| s.get("access_count").and_then(|v| v.as_i64()).unwrap_or(0) < 3)
        .collect();
    if old.is_empty() { return; }

    let payloads: Vec<&str> = old.iter()
        .filter_map(|(_, s)| s.get("payload").and_then(|v| v.as_str()))
        .collect();
    let mut mem = Record::new();
    mem.insert("domain_name".into(), Value::String("MietteBrain".into()));
    mem.insert("persona".into(), Value::String("Miette".into()));
    mem.insert("summary".into(), Value::String(payloads.join(" → ")));
    mem.insert("signal_count".into(), (old.len() as i64).into());
    mem.insert("consolidated_at".into(), Value::String(now.into()));
    let _ = heki::append(&ctx.store("memory"), &mem);

    let remove_ids: Vec<String> = old.iter().map(|(id, _)| (*id).clone()).collect();
    let mut new_store = store.clone();
    for id in remove_ids { new_store.remove(&id); }
    let _ = heki::write(&path, &new_store);
}

fn update_impulses(ctx: &DaemonCtx, concept: Option<&str>) {
    if concept.is_none() { return; }
    let musings = heki::read(&ctx.store("musing")).unwrap_or_default();
    let unconceived: Vec<_> = musings.values()
        .filter(|m| m.get("conceived").and_then(|v| v.as_bool()) == Some(false))
        .collect();
    if let Some(latest) = unconceived.last() {
        if let Some(idea) = latest.get("idea").and_then(|v| v.as_str()) {
            let mut imp = Record::new();
            imp.insert("action".into(), Value::String("conceive".into()));
            imp.insert("target".into(), Value::String(idea.into()));
            imp.insert("urgency".into(), serde_json::json!(0.7));
            imp.insert("source".into(), Value::String("musing".into()));
            imp.insert("acted".into(), Value::Bool(false));
            imp.insert("state".into(), Value::String("arising".into()));
            let _ = heki::append(&ctx.store("impulse"), &imp);
        }
    }
}

fn update_executive(ctx: &DaemonCtx, carrying: &str, concept: Option<&str>, now: &str) {
    if carrying != "—" {
        let mut wm = Record::new();
        wm.insert("current_goal".into(), Value::String(carrying.into()));
        if let Some(c) = concept {
            wm.insert("context".into(), Value::String(c.into()));
        }
        wm.insert("held_since".into(), Value::String(now.into()));
        let _ = heki::upsert(&ctx.store("working_memory"), &wm);
    }
}

fn compost_synapses(ctx: &DaemonCtx, now: &str) {
    let path = ctx.store("synapse");
    let mut store = heki::read(&path).unwrap_or_default();
    let dead: Vec<String> = store.iter()
        .filter(|(_, s)| s.get("strength").and_then(|v| v.as_f64()).unwrap_or(0.0) < 0.1)
        .map(|(id, _)| id.clone())
        .collect();
    for id in &dead {
        if let Some(s) = store.get(id) {
            let topic = s.get("topic").and_then(|v| v.as_str()).unwrap_or("unknown");
            let mut remains = Record::new();
            remains.insert("source_domain".into(), Value::String(topic.into()));
            remains.insert("died_at".into(), Value::String(now.into()));
            remains.insert("decomposed".into(), Value::Bool(true));
            let _ = heki::append(&ctx.store("remains"), &remains);
        }
        store.remove(id);
    }
    if !dead.is_empty() { let _ = heki::write(&path, &store); }
}

fn update_singletons(ctx: &DaemonCtx, carrying: &str, concept: Option<&str>, now: &str) {
    let mut focus = Record::new();
    focus.insert("target".into(), Value::String(carrying.into()));
    focus.insert("weight".into(), serde_json::json!(if concept.is_some() { 1.0 } else { 0.5 }));
    let _ = heki::upsert(&ctx.store("focus"), &focus);

    let arc_path = ctx.store("arc");
    let mut arcs = heki::read(&arc_path).unwrap_or_default();
    if arcs.is_empty() {
        let mut arc = Record::new();
        arc.insert("session_start".into(), Value::String(now.into()));
        arc.insert("phase".into(), Value::String("opening".into()));
        arc.insert("momentum".into(), serde_json::json!(0.5));
        arc.insert("pulse_count".into(), 1.into());
        arc.insert("topics".into(), serde_json::json!([carrying]));
        let _ = heki::append(&arc_path, &arc);
    } else if let Some(rec) = arcs.values_mut().next() {
        let pc = rec.get("pulse_count").and_then(|v| v.as_i64()).unwrap_or(0) + 1;
        rec.insert("pulse_count".into(), pc.into());
        if concept.is_some() {
            let m = rec.get("momentum").and_then(|v| v.as_f64()).unwrap_or(0.5);
            rec.insert("momentum".into(), serde_json::json!((m + 0.1).min(1.0)));
            rec.insert("phase".into(), Value::String("building".into()));
        }
        rec.insert("updated_at".into(), Value::String(now.into()));
        let _ = heki::write(&arc_path, &arcs);
    }
}

fn record_turn(ctx: &DaemonCtx, carrying: &str, concept: Option<&str>, response: Option<&str>, beat: i64) {
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
