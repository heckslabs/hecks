//! [antibody-exempt: rust/src/run_statusline/ — module of the Statuslinen//!  runner ; see mod.rs for the full kernel-floor rationale. Retiresn//!  with mod.rs under i78 when the specializer regenerates from an//!  meta-shape.]n//!n//! Sleep-mode statusline renderer — unchanged from pre-simplification.
//! Reads `consciousness.heki` (and `lucid_dream.heki` during lucid REM)
//! and composes the moon glyph + cycle/stage header + dream narrative.
//!
//! Branches :
//!   - REM             → `cycle X/Y — rem +M:SS · D/N dreams` + summary
//!   - other NREM      → `cycle X/Y — <stage>` (no timer)
//!   - lucid REM       → header prefixed `lucid rem` ; narrative from lucid_dream
//!   - no sleep totals → bare stage label (newborn / partial state)

use super::state::State;
use super::time::Now;

const MOONS: [&str; 8] = ["🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘"];

fn moon_glyph(now: &Now) -> &'static str {
    MOONS[(now.secs % 8) as usize]
}

pub(super) fn render_sleep(s: &State, now: &Now) -> String {
    let phase_label = if s.is_lucid == "yes" && s.sleep_stage == "rem" {
        "lucid rem".to_string()
    } else {
        s.sleep_stage.clone()
    };

    // REM counts UP — dreams have real duration ; NREM phases are
    // content-gated, no timer.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sleep_render_rem_counts_up() {
        let s = State {
            consciousness: "sleeping".into(),
            sleep_stage: "rem".into(),
            sleep_cycle: 3,
            sleep_total: 8,
            phase_ticks: 4,
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
}
