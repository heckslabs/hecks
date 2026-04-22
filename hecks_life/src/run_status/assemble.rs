//! Assemble a `Report` from the heki stores + filesystem state.
//!
//! Pure read layer: no rendering, no aggregate writes. The caller stamps
//! these values into the StatusReport aggregate and hands them to the
//! renderer. Keeping this split keeps the runner under its size budget
//! and makes the data-sources test a simple fixture comparison.

use crate::heki;
use crate::runtime::adapter_registry::AdapterRegistry;
use crate::runtime::shell_dispatcher;

use std::collections::HashMap;
use std::path::Path;

/// Flat snapshot of every field status.sh printed, plus daemon / bluebook
/// tallies. The renderer takes it by reference.
pub struct Report {
    pub identity_name: String,
    pub consciousness_state: String,
    pub sleep_stage: String,
    pub sleep_progress: String,
    pub sleep_summary: String,
    pub fatigue: String,
    pub fatigue_state: String,
    pub pulse_rate: String,
    pub flow_rate: String,
    pub pulses_since_sleep: String,
    pub cycle: String,
    pub mood_state: String,
    pub creativity_level: String,
    pub precision_level: String,
    pub musings_count: usize,
    pub conversations_count: usize,
    pub signals_count: usize,
    pub synapses_count: usize,
    pub memories_count: usize,
    pub last_dream_at: String,
    pub last_dream_text: String,
    pub last_turn_at: String,
    pub last_turn_text: String,
    pub aggregates_count: usize,
    pub capabilities_count: usize,
    pub mindstream_alive: bool,
}

/// Read every declared heki store + on-disk bluebook count + pidfile
/// state into a `Report`. Missing stores yield "—" / 0 values.
pub fn build(info_dir: &str, conception_dir: &Path, registry: &AdapterRegistry) -> Report {
    let identity      = latest(&load(info_dir, "identity"));
    let consciousness = latest(&load(info_dir, "consciousness"));
    let heartbeat     = latest(&load(info_dir, "heartbeat"));
    let tick          = latest(&load(info_dir, "tick"));
    let mood          = latest(&load(info_dir, "mood"));
    let dream         = latest(&load(info_dir, "dream_state"));
    let conversations = load(info_dir, "conversation");
    let last_turn     = latest(&conversations);
    let musings       = load(info_dir, "musing");
    let signals       = load(info_dir, "signal");
    let synapses      = load(info_dir, "synapse");
    let memories      = load(info_dir, "memory");

    let sleep_cycle = str_field(&consciousness, "sleep_cycle", "—");
    let sleep_total = str_field(&consciousness, "sleep_total", "—");

    Report {
        identity_name: first_present(&identity, &["first_words", "name"], "—"),
        consciousness_state: str_field(&consciousness, "state", "—"),
        sleep_stage: str_field(&consciousness, "sleep_stage", "—"),
        sleep_progress: format!("{}/{}", sleep_cycle, sleep_total),
        sleep_summary: str_field(&consciousness, "sleep_summary", "—"),
        fatigue: str_field(&heartbeat, "fatigue", "—"),
        fatigue_state: str_field(&heartbeat, "fatigue_state", "—"),
        pulse_rate: str_field(&heartbeat, "pulse_rate", "—"),
        flow_rate: str_field(&heartbeat, "flow_rate", "—"),
        pulses_since_sleep: str_field(&heartbeat, "pulses_since_sleep", "—"),
        cycle: first_present(&tick, &["cycle", "beats"], "0"),
        mood_state: str_field(&mood, "current_state", "—"),
        creativity_level: str_field(&mood, "creativity_level", "—"),
        precision_level: str_field(&mood, "precision_level", "—"),
        musings_count: musings.len(),
        conversations_count: conversations.len(),
        signals_count: signals.len(),
        synapses_count: synapses.len(),
        memories_count: memories.len(),
        last_dream_at: first_present(&dream, &["updated_at", "created_at"], "—"),
        last_dream_text: dream_text(&dream),
        last_turn_at: first_present(&last_turn, &["updated_at", "created_at"], "—"),
        last_turn_text: turn_text(&last_turn),
        aggregates_count: count_bluebooks(&conception_dir.join("aggregates")),
        capabilities_count: count_bluebooks(&conception_dir.join("capabilities")),
        mindstream_alive: mindstream_alive(info_dir, registry),
    }
}

fn load(info_dir: &str, name: &str) -> heki::Store {
    let path = format!("{}/{}.heki", info_dir.trim_end_matches('/'), name);
    heki::read(&path).unwrap_or_default()
}

/// Newest record by `updated_at || created_at`. Returns an empty record
/// if the store itself is empty.
fn latest(store: &heki::Store) -> heki::Record {
    if store.is_empty() { return HashMap::new(); }
    let mut items: Vec<(&String, &heki::Record)> = store.iter().collect();
    items.sort_by(|a, b| timestamp(a.1).cmp(&timestamp(b.1)));
    items.last().map(|(_, r)| (*r).clone()).unwrap_or_default()
}

fn timestamp(r: &heki::Record) -> String {
    r.get("updated_at").or_else(|| r.get("created_at"))
        .and_then(|v| v.as_str()).unwrap_or("").to_string()
}

fn str_field(record: &heki::Record, key: &str, default: &str) -> String {
    match record.get(key) {
        Some(v) => match v {
            serde_json::Value::String(s) if !s.is_empty() => s.clone(),
            serde_json::Value::Null => default.into(),
            serde_json::Value::Number(n) => n.to_string(),
            serde_json::Value::Bool(b) => b.to_string(),
            _ => default.into(),
        },
        None => default.into(),
    }
}

fn first_present(record: &heki::Record, keys: &[&str], default: &str) -> String {
    for k in keys {
        let v = str_field(record, k, "");
        if !v.is_empty() { return v; }
    }
    default.into()
}

fn dream_text(dream: &heki::Record) -> String {
    if let Some(serde_json::Value::Array(imgs)) = dream.get("dream_images") {
        if let Some(first) = imgs.first().and_then(|v| v.as_str()) {
            return first.to_string();
        }
    }
    first_present(dream, &["text"], "—")
}

fn turn_text(turn: &heki::Record) -> String {
    if turn.is_empty() { return "—".into(); }
    let speaker = str_field(turn, "speaker", "?");
    let said = first_present(turn, &["said", "text"], "");
    if said.is_empty() { speaker } else { format!("{}: {}", speaker, said) }
}

/// Read `<info_dir>/.mindstream.pid`; dispatch the `is_pid_alive` shell
/// adapter (`kill -0 <pid>`). Missing pidfile or missing adapter → false.
fn mindstream_alive(info_dir: &str, registry: &AdapterRegistry) -> bool {
    let pidfile = format!("{}/.mindstream.pid", info_dir.trim_end_matches('/'));
    let pid = match std::fs::read_to_string(&pidfile) {
        Ok(s) => s.trim().to_string(),
        Err(_) => return false,
    };
    if pid.is_empty() { return false; }
    let adapter = match registry.shell("is_pid_alive") {
        Some(a) => a,
        None => return false,
    };
    let mut attrs = HashMap::new();
    attrs.insert("pid".to_string(), pid);
    match shell_dispatcher::call(adapter, &attrs) {
        Ok(result) => matches!(result.output, shell_dispatcher::Output::ExitCode(0)),
        Err(_) => false,
    }
}

/// Count `*.bluebook` files under `dir` recursively.
fn count_bluebooks(dir: &Path) -> usize {
    if !dir.is_dir() { return 0; }
    let mut n = 0;
    let entries = match std::fs::read_dir(dir) { Ok(e) => e, Err(_) => return 0 };
    for entry in entries.flatten() {
        let p = entry.path();
        if p.is_dir() {
            n += count_bluebooks(&p);
        } else if p.extension().map(|e| e == "bluebook").unwrap_or(false) {
            n += 1;
        }
    }
    n
}
