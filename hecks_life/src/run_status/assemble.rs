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

/// One declared daemon's lifecycle state — pidfile + liveness.
pub struct DaemonRow {
    pub name: String,
    pub pid: Option<u32>,
    pub alive: bool,
}

/// Flat snapshot of every field surfaced on the dashboard. The renderer
/// takes it by reference. Fields are grouped by section ; the order
/// here mirrors the rendering order so the data structure reads as the
/// dashboard's table of contents.
pub struct Report {
    // ---- Identity ----
    pub identity_name: String,
    pub pronouns: String,
    pub linked_to: String,
    pub born_at: String,
    pub age_str: String,

    // ---- Consciousness ----
    pub consciousness_state: String,
    pub sleep_stage: String,
    pub sleep_progress: String,
    pub is_lucid: String,
    pub last_wake_at: String,
    pub time_since_wake: String,
    pub sleep_summary: String,

    // ---- Vitals ----
    pub fatigue: String,
    pub fatigue_state: String,
    pub pulse_rate: String,
    pub flow_rate: String,
    pub pulses_since_sleep: String,
    pub cycle: String,

    // ---- Body cycles ----
    pub heart_beats: String,
    pub breath_count: String,
    pub breath_phase: String,
    pub ultradian_phase: String,
    pub ultradian_cycle: String,
    pub circadian_segment: String,

    // ---- Mood ----
    pub mood_state: String,
    pub creativity_level: String,
    pub precision_level: String,

    // ---- Awareness ----
    pub awareness_carrying: String,
    pub awareness_concept: String,
    pub awareness_age_days: String,
    pub awareness_inbox_count: String,
    pub awareness_unfiled_wishes_count: String,
    pub awareness_open_themes: Vec<String>,

    // ---- Memory ----
    pub musings_count: usize,
    pub conversations_count: usize,
    pub signals_count: usize,
    pub synapses_count: usize,
    pub memories_count: usize,

    // ---- Dream wishes ----
    pub wishes_unfiled_count: usize,
    pub wishes_filed_count: usize,
    pub wishes_unfiled_top: Vec<String>,

    // ---- Recent activity ----
    pub last_dream_at: String,
    pub last_dream_text: String,
    pub last_turn_at: String,
    pub last_turn_text: String,

    // ---- Recent commits ----
    pub recent_commits: Vec<String>,

    // ---- Bluebooks ----
    pub aggregates_count: usize,
    pub capabilities_count: usize,

    // ---- Daemons ----
    pub daemons: Vec<DaemonRow>,
}

/// Read every declared heki store + on-disk bluebook count + pidfile
/// state into a `Report`. Missing stores yield "—" / 0 values.
pub fn build(info_dir: &str, conception_dir: &Path, _registry: &AdapterRegistry) -> Report {
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
    let heart         = latest(&load(info_dir, "heart"));
    let breath        = latest(&load(info_dir, "breath"));
    let ultradian     = latest(&load(info_dir, "ultradian"));
    let circadian     = latest(&load(info_dir, "circadian"));
    let awareness     = latest(&load(info_dir, "awareness"));
    let dream_wishes  = load(info_dir, "dream_wish");

    let sleep_cycle = str_field(&consciousness, "sleep_cycle", "—");
    let sleep_total = str_field(&consciousness, "sleep_total", "—");
    let last_wake_at = str_field(&consciousness, "last_wake_at", "—");

    // Awareness's open_themes is a "|"-separated string today (i98) ;
    // split it for tabular display.
    let open_themes_raw = str_field(&awareness, "inbox_open_themes", "");
    let awareness_open_themes: Vec<String> = open_themes_raw
        .split('|')
        .filter(|s| !s.trim().is_empty())
        .map(|s| s.trim().to_string())
        .collect();

    // Dream-wish counts split by status.
    let (wishes_unfiled_count, wishes_filed_count, wishes_unfiled_top) = wish_summary(&dream_wishes);

    let daemons = vec![
        daemon_row(info_dir, "mindstream",  ".mindstream.pid"),
        daemon_row(info_dir, "heart",       ".heart.pid"),
        daemon_row(info_dir, "breath",      ".breath.pid"),
        daemon_row(info_dir, "circadian",   ".circadian.pid"),
        daemon_row(info_dir, "ultradian",   ".ultradian.pid"),
        daemon_row(info_dir, "sleep_cycle", ".sleep_cycle.pid"),
    ];

    let recent_commits = recent_commits(conception_dir, 5);

    Report {
        identity_name: first_present(&identity, &["first_words", "name"], "—"),
        pronouns: str_field(&identity, "pronouns", "—"),
        linked_to: str_field(&identity, "linked_to", "—"),
        born_at: first_present(&identity, &["born", "born_at"], "—"),
        age_str: humanize_age_from_born(&first_present(&identity, &["born", "born_at"], "")),

        consciousness_state: str_field(&consciousness, "state", "—"),
        sleep_stage: str_field(&consciousness, "sleep_stage", "—"),
        sleep_progress: format!("{}/{}", sleep_cycle, sleep_total),
        is_lucid: str_field(&consciousness, "is_lucid", "—"),
        last_wake_at: last_wake_at.clone(),
        time_since_wake: humanize_age(&last_wake_at),
        sleep_summary: str_field(&consciousness, "sleep_summary", "—"),

        fatigue: str_field(&heartbeat, "fatigue", "—"),
        fatigue_state: str_field(&heartbeat, "fatigue_state", "—"),
        pulse_rate: str_field(&heartbeat, "pulse_rate", "—"),
        flow_rate: str_field(&heartbeat, "flow_rate", "—"),
        pulses_since_sleep: str_field(&heartbeat, "pulses_since_sleep", "—"),
        cycle: first_present(&tick, &["cycle", "beats"], "0"),

        heart_beats: str_field(&heart, "beat_count", "—"),
        breath_count: str_field(&breath, "breath_count", "—"),
        breath_phase: str_field(&breath, "phase", "—"),
        ultradian_phase: str_field(&ultradian, "phase", "—"),
        ultradian_cycle: str_field(&ultradian, "cycle_count", "—"),
        circadian_segment: str_field(&circadian, "segment", "—"),

        mood_state: str_field(&mood, "current_state", "—"),
        creativity_level: str_field(&mood, "creativity_level", "—"),
        precision_level: str_field(&mood, "precision_level", "—"),

        awareness_carrying: str_field(&awareness, "carrying", "—"),
        awareness_concept: str_field(&awareness, "concept", "—"),
        awareness_age_days: str_field(&awareness, "age_days", "—"),
        awareness_inbox_count: str_field(&awareness, "inbox_count", "—"),
        awareness_unfiled_wishes_count: wishes_unfiled_count.to_string(),
        awareness_open_themes,

        musings_count: musings.len(),
        conversations_count: conversations.len(),
        signals_count: signals.len(),
        synapses_count: synapses.len(),
        memories_count: memories.len(),

        wishes_unfiled_count,
        wishes_filed_count,
        wishes_unfiled_top,

        last_dream_at: first_present(&dream, &["updated_at", "created_at"], "—"),
        last_dream_text: dream_text(&dream),
        last_turn_at: first_present(&last_turn, &["updated_at", "created_at"], "—"),
        last_turn_text: turn_text(&last_turn),

        recent_commits,

        aggregates_count: count_bluebooks(&conception_dir.join("aggregates")),
        capabilities_count: count_bluebooks(&conception_dir.join("capabilities")),

        daemons,
    }
}

/// Read a daemon's pidfile, check liveness via kill -0.
fn daemon_row(info_dir: &str, name: &str, pidfile_name: &str) -> DaemonRow {
    let path = format!("{}/{}", info_dir.trim_end_matches('/'), pidfile_name);
    let pid = std::fs::read_to_string(&path).ok()
        .and_then(|s| s.trim().parse::<u32>().ok());
    let alive = pid.map(|p| {
        extern "C" { fn kill(pid: i32, sig: i32) -> i32; }
        unsafe { kill(p as i32, 0) == 0 }
    }).unwrap_or(false);
    DaemonRow { name: name.into(), pid, alive }
}

/// Summarise dream_wish records — (unfiled_count, filed_count, top 3 unfiled themes).
fn wish_summary(store: &heki::Store) -> (usize, usize, Vec<String>) {
    let mut unfiled: Vec<(&heki::Record, String)> = Vec::new();
    let mut filed = 0usize;
    for rec in store.values() {
        let status = str_field(rec, "status", "unfiled");
        if status == "filed" {
            filed += 1;
        } else {
            let recorded_at = str_field(rec, "recorded_at", "");
            unfiled.push((rec, recorded_at));
        }
    }
    unfiled.sort_by(|a, b| b.1.cmp(&a.1));
    let top: Vec<String> = unfiled.iter().take(3)
        .map(|(rec, _)| str_field(rec, "theme", "—"))
        .collect();
    (unfiled.len(), filed, top)
}

/// Last `n` commit subjects from git log. Empty on git failure.
fn recent_commits(repo_dir: &Path, n: usize) -> Vec<String> {
    let output = std::process::Command::new("git")
        .arg("-C").arg(repo_dir)
        .arg("log")
        .arg(format!("-{}", n))
        .arg("--pretty=format:%h %s")
        .output();
    match output {
        Ok(out) if out.status.success() => {
            String::from_utf8_lossy(&out.stdout)
                .lines()
                .map(|s| s.to_string())
                .collect()
        }
        _ => Vec::new(),
    }
}

/// "2026-04-26T09:17:59Z" → "2h ago" / "8d ago" / "" if invalid.
fn humanize_age(ts: &str) -> String {
    if ts.is_empty() || ts == "—" { return String::new(); }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64).unwrap_or(0);
    let parsed = parse_utc_seconds(ts).unwrap_or(0);
    if parsed == 0 { return String::new(); }
    let age = now - parsed;
    if age < 0 { return String::new(); }
    if age < 60 { format!("{}s ago", age) }
    else if age < 3600 { format!("{}m ago", age / 60) }
    else if age < 86400 { format!("{}h ago", age / 3600) }
    else { format!("{}d ago", age / 86400) }
}

/// "April 9, 2026" or "2026-04-09" → "17d" / "2 weeks" age string.
fn humanize_age_from_born(born: &str) -> String {
    if born.is_empty() || born == "—" { return "—".into(); }
    // Try ISO date first (YYYY-MM-DD)
    if let Some(secs) = parse_utc_seconds(&format!("{}T00:00:00Z", born.split('T').next().unwrap_or(born))) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64).unwrap_or(0);
        let days = (now - secs) / 86400;
        if days < 0 { return "—".into(); }
        return format!("{}d", days);
    }
    // Fallback : show the raw born string
    born.into()
}

/// Tiny ISO-8601 parser : "YYYY-MM-DDTHH:MM:SSZ" → unix seconds.
fn parse_utc_seconds(ts: &str) -> Option<i64> {
    // Expect 4-2-2 T 2:2:2 Z layout.
    let bytes = ts.as_bytes();
    if bytes.len() < 20 { return None; }
    let year:  i64 = std::str::from_utf8(&bytes[0..4]).ok()?.parse().ok()?;
    let month: i64 = std::str::from_utf8(&bytes[5..7]).ok()?.parse().ok()?;
    let day:   i64 = std::str::from_utf8(&bytes[8..10]).ok()?.parse().ok()?;
    let hour:  i64 = std::str::from_utf8(&bytes[11..13]).ok()?.parse().ok()?;
    let min:   i64 = std::str::from_utf8(&bytes[14..16]).ok()?.parse().ok()?;
    let sec:   i64 = std::str::from_utf8(&bytes[17..19]).ok()?.parse().ok()?;
    // Days from epoch (Howard Hinnant's algorithm, UTC).
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as i64;
    let doy = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days_from_epoch = era * 146097 + doe - 719468;
    Some(days_from_epoch * 86400 + hour * 3600 + min * 60 + sec)
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
