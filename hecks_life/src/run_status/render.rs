//! Report renderer — formats a `Report` into the labeled text status.sh
//! used to print. One function per section keeps the ordering explicit.
//!
//! Color: bold-cyan headers, bold-yellow labels when `on` is true;
//! plaintext when the caller has NO_COLOR or --no-color.

use super::assemble::Report;

pub fn render(r: &Report, on: bool) -> Vec<String> {
    let mut out = Vec::new();
    identity(r, on, &mut out);
    consciousness(r, on, &mut out);
    vitals(r, on, &mut out);
    mood(r, on, &mut out);
    memory(r, on, &mut out);
    recent_activity(r, on, &mut out);
    bluebooks(r, on, &mut out);
    daemons(r, on, &mut out);
    out
}

fn identity(r: &Report, on: bool, out: &mut Vec<String>) {
    push_section(out, "Identity", &[
        ("name", r.identity_name.as_str()),
        ("born_at", "—"),
        ("age", "—"),
    ], on);
}

fn consciousness(r: &Report, on: bool, out: &mut Vec<String>) {
    push_section(out, "Consciousness", &[
        ("state", r.consciousness_state.as_str()),
        ("sleep_stage", r.sleep_stage.as_str()),
        ("sleep_progress", r.sleep_progress.as_str()),
        ("sleep_summary", r.sleep_summary.as_str()),
    ], on);
}

fn vitals(r: &Report, on: bool, out: &mut Vec<String>) {
    push_section(out, "Vitals", &[
        ("fatigue", r.fatigue.as_str()),
        ("fatigue_state", r.fatigue_state.as_str()),
        ("pulse_rate", r.pulse_rate.as_str()),
        ("flow_rate", r.flow_rate.as_str()),
        ("pulses_since_sleep", r.pulses_since_sleep.as_str()),
        ("cycle", r.cycle.as_str()),
    ], on);
}

fn mood(r: &Report, on: bool, out: &mut Vec<String>) {
    push_section(out, "Mood", &[
        ("current_state", r.mood_state.as_str()),
        ("creativity_level", r.creativity_level.as_str()),
        ("precision_level", r.precision_level.as_str()),
    ], on);
}

fn memory(r: &Report, on: bool, out: &mut Vec<String>) {
    let musings = r.musings_count.to_string();
    let conv = r.conversations_count.to_string();
    let sigs = r.signals_count.to_string();
    let syn = r.synapses_count.to_string();
    let mem = r.memories_count.to_string();
    push_section(out, "Memory", &[
        ("musings", musings.as_str()),
        ("conversations", conv.as_str()),
        ("signals", sigs.as_str()),
        ("synapses", syn.as_str()),
        ("memories", mem.as_str()),
    ], on);
}

fn recent_activity(r: &Report, on: bool, out: &mut Vec<String>) {
    push_section(out, "Recent activity", &[
        ("last_dream_at", r.last_dream_at.as_str()),
        ("last_dream", r.last_dream_text.as_str()),
        ("last_turn_at", r.last_turn_at.as_str()),
        ("last_turn", r.last_turn_text.as_str()),
    ], on);
}

fn bluebooks(r: &Report, on: bool, out: &mut Vec<String>) {
    let ac = r.aggregates_count.to_string();
    let cc = r.capabilities_count.to_string();
    push_section(out, "Bluebooks", &[
        ("aggregates", ac.as_str()),
        ("capabilities", cc.as_str()),
    ], on);
}

fn daemons(r: &Report, on: bool, out: &mut Vec<String>) {
    push_section(out, "Daemons", &[
        ("mindstream", if r.mindstream_alive { "alive" } else { "down" }),
    ], on);
}

fn push_section(lines: &mut Vec<String>, title: &str, rows: &[(&str, &str)], on: bool) {
    lines.push(paint(&format!("─── {} ───", title), "1;36", on));
    for (label, value) in rows {
        let lbl = paint(&format!("{}:", label), "1;33", on);
        lines.push(format!("  {} {}", lbl, value));
    }
}

fn paint(text: &str, code: &str, on: bool) -> String {
    if on { format!("\x1b[{}m{}\x1b[0m", code, text) } else { text.to_string() }
}
