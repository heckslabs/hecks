//! Report renderer — formats a `Report` into the comprehensive
//! tabular dashboard. One function per section keeps the ordering
//! explicit and lets each section pick its own column widths.
//!
//! Color: bold-cyan headers, bold-yellow labels when `on` is true ;
//! plaintext when the caller has NO_COLOR or --no-color.

use super::assemble::Report;

const SECTION_WIDTH: usize = 60;
const LABEL_WIDTH: usize = 18;

pub fn render(r: &Report, on: bool) -> Vec<String> {
    let mut out = Vec::new();
    identity(r, on, &mut out);
    consciousness(r, on, &mut out);
    vitals(r, on, &mut out);
    body_cycles(r, on, &mut out);
    mood(r, on, &mut out);
    awareness(r, on, &mut out);
    memory(r, on, &mut out);
    dream_wishes(r, on, &mut out);
    daemons(r, on, &mut out);
    recent_activity(r, on, &mut out);
    recent_commits(r, on, &mut out);
    bluebooks(r, on, &mut out);
    out
}

fn identity(r: &Report, on: bool, out: &mut Vec<String>) {
    push_section(out, "Identity", &[
        ("name",      r.identity_name.as_str()),
        ("born",      r.born_at.as_str()),
        ("age",       r.age_str.as_str()),
        ("pronouns",  r.pronouns.as_str()),
        ("linked_to", r.linked_to.as_str()),
    ], on);
}

fn consciousness(r: &Report, on: bool, out: &mut Vec<String>) {
    let last_wake = if r.time_since_wake.is_empty() {
        r.last_wake_at.clone()
    } else {
        format!("{} ({})", r.last_wake_at, r.time_since_wake)
    };
    push_section(out, "Consciousness", &[
        ("state",          r.consciousness_state.as_str()),
        ("sleep_stage",    r.sleep_stage.as_str()),
        ("sleep_progress", r.sleep_progress.as_str()),
        ("is_lucid",       r.is_lucid.as_str()),
        ("last_wake_at",   last_wake.as_str()),
        ("sleep_summary",  r.sleep_summary.as_str()),
    ], on);
}

fn vitals(r: &Report, on: bool, out: &mut Vec<String>) {
    let fatigue = if r.fatigue_state == "—" || r.fatigue == "—" {
        r.fatigue.clone()
    } else {
        format!("{} ({})", r.fatigue, r.fatigue_state)
    };
    push_section(out, "Vitals", &[
        ("fatigue",            fatigue.as_str()),
        ("pulse_rate",         r.pulse_rate.as_str()),
        ("flow_rate",          r.flow_rate.as_str()),
        ("pulses_since_sleep", r.pulses_since_sleep.as_str()),
        ("cycle",              r.cycle.as_str()),
    ], on);
}

fn body_cycles(r: &Report, on: bool, out: &mut Vec<String>) {
    let breath_str = if r.breath_phase == "—" {
        r.breath_count.clone()
    } else {
        format!("{} (phase: {})", r.breath_count, r.breath_phase)
    };
    let ultradian_str = if r.ultradian_phase == "—" && r.ultradian_cycle == "—" {
        "—".to_string()
    } else {
        format!("cycle {} ({})", r.ultradian_cycle, r.ultradian_phase)
    };
    push_section(out, "Body cycles", &[
        ("heart",     r.heart_beats.as_str()),
        ("breath",    breath_str.as_str()),
        ("ultradian", ultradian_str.as_str()),
        ("circadian", r.circadian_segment.as_str()),
    ], on);
}

fn mood(r: &Report, on: bool, out: &mut Vec<String>) {
    push_section(out, "Mood", &[
        ("current_state",    r.mood_state.as_str()),
        ("creativity_level", r.creativity_level.as_str()),
        ("precision_level",  r.precision_level.as_str()),
    ], on);
}

fn awareness(r: &Report, on: bool, out: &mut Vec<String>) {
    push_section(out, "Awareness", &[
        ("carrying",       r.awareness_carrying.as_str()),
        ("concept",        r.awareness_concept.as_str()),
        ("age_days",       r.awareness_age_days.as_str()),
        ("inbox_count",    r.awareness_inbox_count.as_str()),
        ("unfiled_wishes", r.awareness_unfiled_wishes_count.as_str()),
    ], on);
    if !r.awareness_open_themes.is_empty() {
        let lbl = paint(&format!("{:width$}", "open_themes:", width = LABEL_WIDTH), "1;33", on);
        out.push(format!("  {} (top {})", lbl, r.awareness_open_themes.len()));
        for (i, theme) in r.awareness_open_themes.iter().enumerate() {
            out.push(format!("  {}{:>2}. {}", " ".repeat(LABEL_WIDTH + 1), i + 1, truncate(theme, 60)));
        }
    }
}

fn memory(r: &Report, on: bool, out: &mut Vec<String>) {
    let m = r.musings_count.to_string();
    let c = r.conversations_count.to_string();
    let s = r.signals_count.to_string();
    let y = r.synapses_count.to_string();
    let me = r.memories_count.to_string();
    push_section(out, "Memory", &[
        ("musings",       m.as_str()),
        ("conversations", c.as_str()),
        ("signals",       s.as_str()),
        ("synapses",      y.as_str()),
        ("memories",      me.as_str()),
    ], on);
}

fn dream_wishes(r: &Report, on: bool, out: &mut Vec<String>) {
    let u = r.wishes_unfiled_count.to_string();
    let f = r.wishes_filed_count.to_string();
    push_section(out, "Dream wishes", &[
        ("unfiled", u.as_str()),
        ("filed",   f.as_str()),
    ], on);
    if !r.wishes_unfiled_top.is_empty() {
        let lbl = paint(&format!("{:width$}", "recent_unfiled:", width = LABEL_WIDTH), "1;33", on);
        out.push(format!("  {}", lbl));
        for (i, theme) in r.wishes_unfiled_top.iter().enumerate() {
            out.push(format!("  {}{:>2}. {}", " ".repeat(LABEL_WIDTH + 1), i + 1, truncate(theme, 60)));
        }
    }
}

fn daemons(r: &Report, on: bool, out: &mut Vec<String>) {
    out.push(paint(&format!("─── Daemons {}", "─".repeat(SECTION_WIDTH.saturating_sub(12))), "1;36", on));
    // Tabular : name (left), status, pid (right)
    for d in &r.daemons {
        let status = if d.alive {
            paint("alive", "32", on)
        } else {
            paint("down ", "31", on)
        };
        let pid = match d.pid {
            Some(p) => format!("pid {}", p),
            None => "—".into(),
        };
        out.push(format!("  {:width$} {}  {}", d.name, status, pid, width = LABEL_WIDTH));
    }
}

fn recent_activity(r: &Report, on: bool, out: &mut Vec<String>) {
    let last_dream_at = if r.last_dream_at != "—" {
        let age = humanize_age_simple(&r.last_dream_at);
        if age.is_empty() { r.last_dream_at.clone() } else { format!("{} ({})", r.last_dream_at, age) }
    } else { r.last_dream_at.clone() };
    let last_turn_at = if r.last_turn_at != "—" {
        let age = humanize_age_simple(&r.last_turn_at);
        if age.is_empty() { r.last_turn_at.clone() } else { format!("{} ({})", r.last_turn_at, age) }
    } else { r.last_turn_at.clone() };
    let last_dream_short = truncate(&r.last_dream_text, 60);
    let last_turn_short = truncate(&r.last_turn_text, 60);
    push_section(out, "Recent activity", &[
        ("last_dream_at", last_dream_at.as_str()),
        ("last_dream",    last_dream_short.as_str()),
        ("last_turn_at",  last_turn_at.as_str()),
        ("last_turn",     last_turn_short.as_str()),
    ], on);
}

fn recent_commits(r: &Report, on: bool, out: &mut Vec<String>) {
    out.push(paint(&format!("─── Recent commits {}", "─".repeat(SECTION_WIDTH.saturating_sub(19))), "1;36", on));
    if r.recent_commits.is_empty() {
        out.push("  (no git history)".into());
        return;
    }
    for line in &r.recent_commits {
        out.push(format!("  {}", truncate(line, 75)));
    }
}

fn bluebooks(r: &Report, on: bool, out: &mut Vec<String>) {
    let a = r.aggregates_count.to_string();
    let c = r.capabilities_count.to_string();
    push_section(out, "Bluebooks", &[
        ("aggregates",   a.as_str()),
        ("capabilities", c.as_str()),
    ], on);
}

fn push_section(lines: &mut Vec<String>, title: &str, rows: &[(&str, &str)], on: bool) {
    let dashes = SECTION_WIDTH.saturating_sub(title.chars().count() + 4);
    lines.push(paint(&format!("─── {} {}", title, "─".repeat(dashes)), "1;36", on));
    for (label, value) in rows {
        let label_padded = format!("{}:", label);
        let lbl = paint(&format!("{:width$}", label_padded, width = LABEL_WIDTH), "1;33", on);
        lines.push(format!("  {} {}", lbl, value));
    }
}

fn paint(text: &str, code: &str, on: bool) -> String {
    if on { format!("\x1b[{}m{}\x1b[0m", code, text) } else { text.to_string() }
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max { s.to_string() }
    else { format!("{}…", s.chars().take(max - 1).collect::<String>()) }
}

/// Tiny helper for "Xh ago" suffixes — duplicates assemble's logic
/// to avoid cross-module dependencies on parse_utc_seconds.
fn humanize_age_simple(ts: &str) -> String {
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
