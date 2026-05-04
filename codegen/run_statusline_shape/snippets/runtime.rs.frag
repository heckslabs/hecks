
/// Drain stdin (Claude Code harness JSON), parse for the session's
/// workspace.current_dir and chdir to it so env::current_dir() reflects
/// the user's terminal cwd (not the harness's launch dir). Resolve
/// info dirs, read state, run coherence, render, print.
pub fn run() {
    use std::io::Read;
    let mut input = String::new();
    let _ = std::io::stdin().read_to_string(&mut input);

    // Claude Code's statusline JSON carries the session's cwd at
    // workspace.current_dir. Without this chdir, env::current_dir()
    // returns whatever shell the harness was launched from — usually
    // the project root, never the user's actual `cd`-ed location.
    // The active-bluebook detection (i241) needs the user's cwd to
    // know which project context they're in.
    if !input.is_empty() {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&input) {
            if let Some(d) = v.pointer("/workspace/current_dir")
                              .and_then(|x| x.as_str()) {
                let _ = env::set_current_dir(d);
            }
        }
    }

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

/// Find the active bluebook from cwd. Walks up to 10 levels looking
/// for a directory that has an `inbox/` subdirectory, optionally with
/// a sibling `<name>.bluebook` file (the i241 per-bluebook convention).
/// Skips `hecks_conception/` itself : its inbox is the framework
/// default rendered as `(global)`, not a per-bluebook context.
///
/// Returns (bluebook_name, inbox_dir). Name preferred from the
/// `<name>.bluebook` file stem ; falls back to the directory basename
/// when the bluebook hasn't been conceived yet (binbuddy's case today).
///
/// Pure cwd-based : no cross-project ambient guessing. When cwd offers
/// no per-bluebook context, render_awake renders the conception inbox
/// as `✉️ N (global)`.
fn find_active_bluebook() -> Option<(String, PathBuf)> {
    let cwd = env::current_dir().ok()?;
    let mut cur: PathBuf = cwd;
    for _ in 0..10 {
        if let Some(hit) = bluebook_at(&cur) {
            return Some(hit);
        }
        cur = cur.parent()?.to_path_buf();
    }
    None
}

/// Returns Some((name, inbox_dir)) if the given directory matches the
/// per-bluebook convention : has an `inbox/` subdir, isn't
/// `hecks_conception/` (whose inbox is rendered as `(global)`), and
/// optionally has a `<name>.bluebook` (stem becomes the name ; dir
/// basename is the fallback).
fn bluebook_at(dir: &Path) -> Option<(String, PathBuf)> {
    if dir.file_name().map_or(false, |n| n == "hecks_conception") {
        return None;
    }
    let inbox_dir = dir.join("inbox");
    if !inbox_dir.is_dir() { return None; }
    let mut name: Option<String> = None;
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.extension().map_or(false, |e| e == "bluebook") {
                if let Some(stem) = p.file_stem().and_then(|s| s.to_str()) {
                    name = Some(stem.to_string());
                    break;
                }
            }
        }
    }
    let resolved = name.or_else(|| {
        dir.file_name().and_then(|s| s.to_str()).map(|s| s.to_string())
    })?;
    Some((resolved, inbox_dir))
}

/// Count `*.md` cards in a markdown inbox whose YAML frontmatter has
/// `status: queued`. Cheap line-prefix match — no full YAML dep.
fn count_md_inbox_queued(inbox_dir: &Path) -> i64 {
    if !inbox_dir.is_dir() { return 0; }
    let mut count: i64 = 0;
    if let Ok(entries) = std::fs::read_dir(inbox_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map_or(false, |e| e == "md") {
                if let Ok(text) = std::fs::read_to_string(&path) {
                    if md_status_is_queued(&text) {
                        count += 1;
                    }
                }
            }
        }
    }
    count
}

fn md_status_is_queued(text: &str) -> bool {
    let body = match text.strip_prefix("---\n") {
        Some(b) => b,
        None => return false,
    };
    let end = match body.find("\n---\n") {
        Some(e) => e,
        None => return false,
    };
    body[..end].lines().any(|l| l.trim() == "status: queued")
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
    sleep_cycle: i64,
    sleep_total: i64,
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
            s.sleep_cycle          = int_field(rec, "sleep_cycle");
            s.sleep_total          = int_field(rec, "sleep_total");
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

    // Timer math : REM counts UP because dreams have real duration —
    // Claude generates each dream image, the phase holds until the
    // dream completes. NREM phases (light/deep/final_light) fly through
    // naturally — they are content-gated, not time-gated, so the bar
    // shows no timer at all for them.
    let timer = if s.sleep_stage == "rem" {
        let elapsed = s.phase_ticks * 10;
        let mins = elapsed / 60;
        let secs = elapsed % 60;
        format!("+{}:{:02}", mins, secs)
    } else {
        String::new()
    };

    let header = if s.sleep_stage == "rem" {
        if s.sleep_total > 0 {
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
    } else if s.sleep_total > 0 {
        format!("cycle {}/{} — {}", s.sleep_cycle, s.sleep_total, phase_label)
    } else {
        phase_label.clone()
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
    // Per-bluebook inbox detection (i241 convention). When cwd is
    // inside a project with a sibling `inbox/` directory, that
    // bluebook owns the slot : show its queued count + name in
    // parentheses. Otherwise the conception inbox is shown, marked
    // (global) so it's clear we're outside any specific bluebook.
    match find_active_bluebook() {
        Some((name, inbox_dir)) => {
            let count = count_md_inbox_queued(&inbox_dir);
            out.push_str(&format!(" ✉️ {} ({})", count, name));
        }
        None => {
            if s.inbox_count > 0 {
                out.push_str(&format!(" ✉️ {} (global)", s.inbox_count));
            }
        }
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
