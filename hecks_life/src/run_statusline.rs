//! Statusline runner — emits Miette's one-line body status to stdout.
//!
//! [antibody-exempt: hecks_life/src/run_statusline.rs — Rust runner
//!  for the Statusline capability declared in
//!  hecks_conception/capabilities/statusline/. Mirrors run_status/
//!  shape : reads body heki, branches on consciousness state,
//!  composes a single line. Replaces statusline-command.sh's 273-
//!  line shell rendering. Retires under i78 (specializer-files-as-
//!  bluebook) when the runner is regenerated from
//!  capability_runner_shape.]
//!
//! Fired by `hecks-life statusline` (CLI subcommand). Claude Code's
//! statusline-command.sh becomes a 3-line wrapper that exec's this.
//!
//! ## Inputs (heki + filesystem under HECKS_INFO)
//!
//!   - heartbeat.heki        → fatigue_state, updated_at (idle check)
//!   - mood.heki             → current_state
//!   - consciousness.heki    → state, sleep_*, is_lucid, dream_pulses
//!   - tick.heki             → cycle (beats counter)
//!   - musing_mint.heki      → total_minted (idea count)
//!   - invention.heki        → count of status=proposed
//!   - lucid_dream.heki      → latest_narrative (lucid REM only)
//!   - claude_assist.heki    → provider (claude/local/off)
//!   - inbox.heki            → count of status=queued (from public dir)
//!   - .mindstream.pid       → daemon liveness (kill -0)
//!   - .last_dispatch        → cmd + timestamp (breadcrumb)
//!   - /tmp/miette_minting   → minting-in-progress flag (animates bulb)
//!
//! ## Side process
//!
//! Runs `status_coherence.sh <info>` ; on non-zero exit, appends
//! the violation lines to `<info>/.coherence.log` with a UTC
//! timestamp and degrades the mood glyph to ⚠.
//!
//! ## Time-based animations
//!
//!   moon    : ["🌑"…"🌘"][secs % 8]              — slow drift
//!   thought : ["💭","💡","💭","✨"][secs % 4]      — flicker
//!   heart   : ["🖤","❤️"][nanos / 333ms % 2]      — half-second pulse
//!   bulb    : ["💡","🌟","✨","💫"][secs % 4]      — minting only
//!
//! ## Branch
//!
//!   consciousness == "sleeping" → moon + cycle counter + timer + narrative
//!   consciousness != "sleeping" → heart + beats + mood + fatigue + ideas
//!                                  + inventions + inbox + provider + bulb
//!                                  + breadcrumb (last_dispatch < 30s old)

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::heki;
use crate::heki_query::{filter_records, Filter};

/// Drain stdin (Claude Code harness sends JSON we ignore), resolve
/// info dirs, read state, run coherence, render, print.
pub fn run() {
    use std::io::Read;
    let _ = std::io::stdin().read_to_string(&mut String::new());

    let info = resolve_info_dir();
    let public_info = resolve_public_info_dir(&info);
    let coherence_dir = resolve_coherence_dir();

    let state = read_state(&info, &public_info);
    let coherence_ok = run_coherence_check(&coherence_dir, &info);
    let now = Now::wall_clock();

    let line = if state.consciousness == "sleeping" {
        render_sleep(&state, &now)
    } else {
        render_awake(&state, &now, coherence_ok, &info)
    };

    println!("{}", line);
}

// ────────────────────────────────────────────────────────────────
// Path resolution
// ────────────────────────────────────────────────────────────────

/// Delegates to `heki::resolve_info_dir` — the canonical i154 helper.
/// Same fallback order : HECKS_INFO env → ../miette-state/information
/// sibling → hecks_conception/information → literal fallback. Kept as
/// a thin wrapper so internal callsites don't change.
fn resolve_info_dir() -> PathBuf {
    crate::heki::resolve_info_dir()
}

/// Public information dir always lives in the hecks repo. inbox.heki
/// is here even when private state is elsewhere — framework dev notes
/// are public.
fn resolve_public_info_dir(info: &Path) -> PathBuf {
    if let Some(repo) = walk_up_for_repo_root() {
        return repo.join("hecks_conception/information");
    }
    info.to_path_buf()
}

/// Where status_coherence.sh lives — same dir as the original
/// statusline-command.sh did, i.e. `hecks_conception/`.
fn resolve_coherence_dir() -> Option<PathBuf> {
    walk_up_for_repo_root().map(|r| r.join("hecks_conception"))
}

/// Walk up from current_exe to find the repo root (the dir containing
/// `hecks_conception/`). Same heuristic the rest of the body uses.
fn walk_up_for_repo_root() -> Option<PathBuf> {
    let exe = env::current_exe().ok()?.canonicalize().ok()?;
    let mut cur: PathBuf = exe.parent()?.to_path_buf();
    for _ in 0..6 {
        if cur.join("hecks_conception").is_dir() {
            return Some(cur);
        }
        cur = cur.parent()?.to_path_buf();
    }
    None
}

// ────────────────────────────────────────────────────────────────
// State — all heki sources read up front
// ────────────────────────────────────────────────────────────────

#[derive(Default)]
struct State {
    // From consciousness.heki
    consciousness: String,
    sleep_summary: String,
    sleep_stage: String,
    sleep_cycle: String,
    sleep_total: String,
    phase_ticks: i64,
    is_lucid: String,
    dream_pulses: i64,
    dream_pulses_needed: i64,

    // From heartbeat.heki
    fatigue: String,

    // From mood.heki
    mood: String,

    // From tick.heki
    beats_raw: i64,

    // From musing_mint.heki
    musings_count: i64,

    // From invention.heki (filtered count)
    inventions_count: i64,

    // From inbox.heki (filtered count, public dir)
    inbox_count: i64,

    // From claude_assist.heki
    provider: String,

    // From lucid_dream.heki (only when lucid REM)
    lucid_narrative: String,
}

fn read_state(info: &Path, public_info: &Path) -> State {
    let mut s = State::default();

    if let Ok(store) = heki::read(&heki::path_for_lookup(&info.to_string_lossy(), "consciousness")) {
        if let Some(rec) = heki::latest(&store) {
            s.consciousness        = string_field(rec, "state");
            s.sleep_summary        = string_field(rec, "sleep_summary");
            s.sleep_stage          = string_field(rec, "sleep_stage");
            s.sleep_cycle          = string_field(rec, "sleep_cycle");
            s.sleep_total          = string_field(rec, "sleep_total");
            s.phase_ticks          = int_field(rec, "phase_ticks");
            s.is_lucid             = string_field(rec, "is_lucid");
            s.dream_pulses         = int_field(rec, "dream_pulses");
            s.dream_pulses_needed  = int_field(rec, "dream_pulses_needed");
            if s.dream_pulses_needed == 0 { s.dream_pulses_needed = 5; }
        }
    }

    if let Ok(store) = heki::read(&heki::path_for_lookup(&info.to_string_lossy(), "heartbeat")) {
        if let Some(rec) = heki::latest(&store) {
            s.fatigue = string_field(rec, "fatigue_state");
        }
    }

    if let Ok(store) = heki::read(&heki::path_for_lookup(&info.to_string_lossy(), "mood")) {
        if let Some(rec) = heki::latest(&store) {
            s.mood = string_field(rec, "current_state");
        }
    }

    if let Ok(store) = heki::read(&heki::path_for_lookup(&info.to_string_lossy(), "tick")) {
        if let Some(rec) = heki::latest(&store) {
            s.beats_raw = int_field(rec, "cycle");
        }
    }

    if let Ok(store) = heki::read(&heki::path_for_lookup(&info.to_string_lossy(), "musing_mint")) {
        if let Some(rec) = heki::latest(&store) {
            s.musings_count = int_field(rec, "total_minted");
        }
    }

    // Filter-count helpers : inventions where status=proposed,
    // inbox where status=queued. heki_query::Filter::parse + filter_records.
    s.inventions_count = filter_count(&heki::path_for_lookup(&info.to_string_lossy(), "invention"), "status=proposed");
    s.inbox_count      = filter_count(&heki::path_for_lookup(&public_info.to_string_lossy(), "inbox"), "status=queued");

    if let Ok(store) = heki::read(&heki::path_for_lookup(&info.to_string_lossy(), "claude_assist")) {
        if let Some(rec) = heki::latest(&store) {
            s.provider = string_field(rec, "provider");
        }
    }

    if s.is_lucid == "yes" && s.sleep_stage == "rem" {
        if let Ok(store) = heki::read(&heki::path_for_lookup(&info.to_string_lossy(), "lucid_dream")) {
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

fn filter_count(path: &str, where_spec: &str) -> i64 {
    let store = match heki::read(path) {
        Ok(s) => s,
        Err(_) => return 0,
    };
    let filter = match Filter::parse(where_spec) {
        Ok(f) => f,
        Err(_) => return 0,
    };
    filter_records(&store, &[filter]).len() as i64
}

// ────────────────────────────────────────────────────────────────
// Coherence check — subprocess + .coherence.log append
// ────────────────────────────────────────────────────────────────

/// Run `<coherence_dir>/status_coherence.sh <info>`. Returns true
/// when exit==0 ; false otherwise (and appends the violation lines
/// to <info>/.coherence.log with a UTC timestamp).
fn run_coherence_check(coherence_dir: &Option<PathBuf>, info: &Path) -> bool {
    let dir = match coherence_dir {
        Some(d) => d,
        None => return true, // can't check — assume ok (legacy behavior)
    };
    let script = dir.join("status_coherence.sh");
    if !script.is_file() {
        return true;
    }
    let output = Command::new("bash")
        .arg(&script)
        .arg(info)
        .output();
    let output = match output {
        Ok(o) => o,
        Err(_) => return true,
    };
    if output.status.success() {
        return true;
    }
    // Violations on stderr ; append to .coherence.log with timestamp.
    let log = info.join(".coherence.log");
    let ts = utc_iso_now();
    let stderr = String::from_utf8_lossy(&output.stderr);
    let mut content = String::new();
    for line in stderr.lines() {
        if line.is_empty() { continue; }
        content.push_str(&format!("{} {}\n", ts, line));
    }
    if !content.is_empty() {
        let _ = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log)
            .and_then(|mut f| {
                use std::io::Write;
                f.write_all(content.as_bytes())
            });
    }
    false
}

fn utc_iso_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let z = secs / 86400;
    let s = secs.rem_euclid(86400);
    let hour = s / 3600;
    let min = (s % 3600) / 60;
    let sec = s % 60;
    let z_shift = z + 719468;
    let era = if z_shift >= 0 { z_shift } else { z_shift - 146096 } / 146097;
    let doe = (z_shift - era * 146097) as i64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, m, d, hour, min, sec)
}

// ────────────────────────────────────────────────────────────────
// Time-based animations
// ────────────────────────────────────────────────────────────────

struct Now {
    secs: u64,
    nanos_total: u128,
}

impl Now {
    fn wall_clock() -> Self {
        let dur = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
        Self {
            secs: dur.as_secs(),
            nanos_total: dur.as_nanos(),
        }
    }
}

const MOONS:   [&str; 8] = ["🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘"];
const HEARTS:  [&str; 2] = ["🖤", "❤️"];
const BULBS:   [&str; 4] = ["💡", "🌟", "✨", "💫"];

fn moon_glyph(now: &Now) -> &'static str {
    MOONS[(now.secs % 8) as usize]
}

fn heart_glyph(now: &Now) -> &'static str {
    // 333ms phase from wall-clock nanoseconds — odd bucket count
    // between consecutive 1Hz polls guarantees parity flips. Same
    // formula statusline-command.sh used post-PR e0abc604.
    let phase = (now.nanos_total / 333_000_000) % 2;
    HEARTS[phase as usize]
}

fn bulb_glyph(now: &Now, minting: bool) -> &'static str {
    if minting {
        BULBS[(now.secs % 4) as usize]
    } else {
        "💡"
    }
}

// ────────────────────────────────────────────────────────────────
// Render — sleep mode
// ────────────────────────────────────────────────────────────────

fn render_sleep(s: &State, now: &Now) -> String {
    let phase_label = if s.is_lucid == "yes" && s.sleep_stage == "rem" {
        "lucid rem".to_string()
    } else {
        s.sleep_stage.clone()
    };

    // Timer math : REM counts UP (unknown duration) ; other phases
    // count DOWN from 12-tick floor (2 minutes at 10s/tick).
    let timer = if s.sleep_stage == "rem" {
        let elapsed = s.phase_ticks * 10;
        let mins = elapsed / 60;
        let secs = elapsed % 60;
        format!("+{}:{:02}", mins, secs)
    } else {
        let remaining = (12 - s.phase_ticks) * 10;
        if remaining < 0 {
            format!("+{}s", -remaining)
        } else {
            let mins = remaining / 60;
            let secs = remaining % 60;
            format!("{}:{:02}", mins, secs)
        }
    };

    let header = if s.sleep_stage == "rem" {
        if !s.sleep_cycle.is_empty() && !s.sleep_total.is_empty() {
            format!(
                "cycle {}/{} — {} {} · {}/{} dreams",
                s.sleep_cycle, s.sleep_total, phase_label, timer,
                s.dream_pulses, s.dream_pulses_needed
            )
        } else {
            format!(
                "{} {} · {}/{} dreams",
                phase_label, timer, s.dream_pulses, s.dream_pulses_needed
            )
        }
    } else if !s.sleep_cycle.is_empty() && !s.sleep_total.is_empty() {
        format!("cycle {}/{} — {} ({})", s.sleep_cycle, s.sleep_total, phase_label, timer)
    } else {
        format!("{} ({})", phase_label, timer)
    };

    // Lucid REM prefers lucid_dream.latest_narrative ; otherwise
    // sleep_summary is the regular dream impression.
    let narrative = if s.is_lucid == "yes" && s.sleep_stage == "rem" && !s.lucid_narrative.is_empty() {
        format!("✨ {}", s.lucid_narrative)
    } else {
        s.sleep_summary.clone()
    };

    if narrative.is_empty() {
        format!("{} {}", moon_glyph(now), header)
    } else {
        format!("{} {}  {}", moon_glyph(now), header, narrative)
    }
}

// ────────────────────────────────────────────────────────────────
// Render — awake mode
// ────────────────────────────────────────────────────────────────

fn render_awake(s: &State, now: &Now, coherence_ok: bool, info: &Path) -> String {
    let mut mood_icon = mood_icon_for(&s.mood);
    if !coherence_ok {
        mood_icon = "⚠";
    }

    let beats = format_beats(s.beats_raw);
    let fatigue_icon = fatigue_icon_for(&s.fatigue);
    let provider_badge = provider_badge_for(&s.provider);
    let minting = Path::new("/tmp/miette_minting").exists();
    let bulb = bulb_glyph(now, minting);

    let mut out = format!("{} {} {} {}", heart_glyph(now), beats, mood_icon, s.mood);
    if !fatigue_icon.is_empty() {
        out.push_str(&format!(" {} {}", fatigue_icon, s.fatigue));
    }
    out.push_str(&format!(" 💭 {}", s.musings_count));
    if s.inventions_count > 0 {
        out.push_str(&format!(" 🔬 {}", s.inventions_count));
    }
    if s.inbox_count > 0 {
        out.push_str(&format!(" ✉️ {}", s.inbox_count));
    }
    out.push_str(&format!(" {}", provider_badge));
    if !s.sleep_summary.is_empty() && s.sleep_summary != "present" {
        out.push_str(&format!(" {} {}", bulb, s.sleep_summary));
    }

    // Last-dispatched-command breadcrumb — surface while fresh
    // (< 30s). Older than that the cascade has settled, suppress.
    if let Some(crumb) = read_last_dispatch(info) {
        out.push_str(&format!(" 🛠️  {}", crumb));
    }

    out
}

fn mood_icon_for(mood: &str) -> &'static str {
    match mood {
        "refreshed" => "😊",
        "excited"   => "🤩",
        "focused"   => "🎯",
        "curious"   => "🤔",
        "drifting"  => "🌀",
        "groggy"    => "😵\u{200d}💫",
        "vivid"     => "✨",
        "sleeping"  => "😴",
        "flowing"   => "🌊",
        "deep"      => "🧘",
        "oceanic"   => "🌌",
        _           => "😐",
    }
}

fn fatigue_icon_for(fatigue: &str) -> &'static str {
    match fatigue {
        "alert"      => "⚡",
        "focused"    => "🎯",
        "normal"     => "",
        "tired"      => "🥱",
        "exhausted"  => "😩",
        "delirious"  => "🫠",
        _            => "",
    }
}

fn provider_badge_for(provider: &str) -> &'static str {
    match provider {
        "local" => "🦙",
        "off"   => "🚫",
        _       => "🤖", // claude is the default when unset
    }
}

/// Format beat count : ≥1M → "X.XXm" ; ≥1k → "X.XXk" ; else raw.
fn format_beats(b: i64) -> String {
    if b >= 1_000_000 {
        format!("{:.2}m", (b as f64) / 1_000_000.0)
    } else if b >= 1_000 {
        format!("{:.2}k", (b as f64) / 1_000.0)
    } else {
        b.to_string()
    }
}

/// Read `<info>/.last_dispatch` (two lines : cmd, unix_seconds). If
/// the timestamp is < 30s old, return Some(cmd) ; otherwise None.
fn read_last_dispatch(info: &Path) -> Option<String> {
    let content = fs::read_to_string(info.join(".last_dispatch")).ok()?;
    let mut lines = content.lines();
    let cmd = lines.next()?.to_string();
    let ts: i64 = lines.next()?.parse().ok()?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .ok()?;
    if cmd.is_empty() || (now - ts) >= 30 {
        return None;
    }
    Some(cmd)
}

// ────────────────────────────────────────────────────────────────
// Tests — pure render functions get covered ; subprocess + path
// resolution stay manual (the smoke test exercises them end-to-end).
// ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn beats_format_thresholds() {
        assert_eq!(format_beats(0), "0");
        assert_eq!(format_beats(999), "999");
        assert_eq!(format_beats(1_000), "1.00k");
        assert_eq!(format_beats(82_416), "82.42k");
        assert_eq!(format_beats(1_500_000), "1.50m");
    }

    #[test]
    fn mood_icon_table_covers_body_emitters() {
        // body.bluebook emits these six explicitly — every one must
        // map to a non-fallback icon, otherwise the statusline looks
        // like it lost a signal. Same lockdown as the regression
        // smoke test.
        for mood in ["refreshed", "excited", "focused", "curious", "drifting", "groggy"] {
            assert_ne!(mood_icon_for(mood), "😐", "{} should have a real icon", mood);
        }
        assert_eq!(mood_icon_for("not_a_mood"), "😐"); // fallback works
    }

    #[test]
    fn fatigue_icon_table_covers_emitters() {
        for f in ["alert", "focused", "tired", "exhausted", "delirious"] {
            assert!(!fatigue_icon_for(f).is_empty(), "{} should have an icon", f);
        }
        assert_eq!(fatigue_icon_for("normal"), ""); // intentionally empty
    }

    #[test]
    fn provider_badge_covers_three_states() {
        assert_eq!(provider_badge_for("claude"), "🤖");
        assert_eq!(provider_badge_for("local"),  "🦙");
        assert_eq!(provider_badge_for("off"),    "🚫");
        assert_eq!(provider_badge_for(""),       "🤖"); // default
    }

    #[test]
    fn awake_render_includes_required_pieces() {
        let s = State {
            consciousness: "attentive".into(),
            mood: "focused".into(),
            fatigue: "alert".into(),
            beats_raw: 1234,
            musings_count: 7,
            inventions_count: 0,
            inbox_count: 3,
            provider: "claude".into(),
            ..Default::default()
        };
        let now = Now { secs: 0, nanos_total: 0 };
        let line = render_awake(&s, &now, true, Path::new("/tmp/nope"));
        assert!(line.contains("focused"));
        assert!(line.contains("1.23k"));
        assert!(line.contains("💭 7"));
        assert!(line.contains("✉️ 3"));
        assert!(line.contains("🤖"));
        assert!(!line.contains("🔬"), "no inventions row when count=0");
    }

    #[test]
    fn sleep_render_rem_counts_up() {
        let s = State {
            consciousness: "sleeping".into(),
            sleep_stage: "rem".into(),
            sleep_cycle: "3".into(),
            sleep_total: "8".into(),
            phase_ticks: 4,            // 40 seconds elapsed
            dream_pulses: 2,
            dream_pulses_needed: 5,
            ..Default::default()
        };
        let now = Now { secs: 0, nanos_total: 0 };
        let line = render_sleep(&s, &now);
        assert!(line.contains("cycle 3/8"));
        assert!(line.contains("rem +0:40"));
        assert!(line.contains("2/5 dreams"));
    }

    #[test]
    fn coherence_violation_degrades_mood() {
        let s = State {
            consciousness: "attentive".into(),
            mood: "focused".into(),
            ..Default::default()
        };
        let now = Now { secs: 0, nanos_total: 0 };
        let line = render_awake(&s, &now, false, Path::new("/tmp/nope"));
        assert!(line.contains("⚠"), "coherence false → mood glyph degraded");
    }
}
