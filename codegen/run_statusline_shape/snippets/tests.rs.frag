
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
        for f in ["rested", "alert", "focused", "tired", "exhausted", "delirious"] {
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
        // Hermeticity : `find_active_bluebook` walks cwd up to 10 levels
        // looking for an `inbox/` sibling (or for a parent directory
        // that contains `hecks_conception/`, which anchors as
        // `(global)`), then falls back to scanning `$HOME/Projects/*/inbox/`
        // by mtime. Either reach can find a sibling repo (binbuddy/,
        // miette/, …) or detect hecks_conception via the cwd walk and
        // flip the inbox row away from the bare-fallback shape this
        // test asserts. Pin all three : `HOME` to a non-existent path
        // neutralises the mtime fallback ; cwd to `/tmp` (no inbox/
        // anywhere up the tree, no hecks_conception/ either) neutralises
        // the cwd walk regardless of where cargo runs from.
        std::env::set_var("HOME", "/tmp/hecks_statusline_test_no_home");
        let _ = std::env::set_current_dir("/tmp");
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
        assert!(line.contains("1.23k"));
        assert!(!line.contains("focused"), "mood word is hidden");
        assert!(!line.contains("💭"), "musings count is hidden");
        assert!(line.contains("✉️ 3"));
        assert!(line.contains("🤖"));
        assert!(!line.contains("🔬"), "no inventions row when count=0");
    }

    #[test]
    fn sleep_render_rem_counts_up() {
        let s = State {
            consciousness: "sleeping".into(),
            sleep_stage: "rem".into(),
            sleep_cycle: 3,
            sleep_total: 8,
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
