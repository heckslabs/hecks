
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
        for f in ["rested", "limber", "tuned", "tired", "exhausted", "spent"] {
            assert!(!fatigue_icon_for(f).is_empty(), "{} should have an icon", f);
        }
        assert_eq!(fatigue_icon_for("normal"), ""); // intentionally empty
    }

    #[test]
    fn provider_badge_covers_three_states() {
        assert_eq!(provider_badge_for("claude"), "🤖");
        assert_eq!(provider_badge_for("local"),  "🦙");
        // "off" deliberately returns empty — see provider_badge_for's
        // doc comment. The render code gates on !is_empty(), so off
        // shows nothing rather than a 🚫 emoji that would be visual
        // noise on a working statusline.
        assert_eq!(provider_badge_for("off"),    "");
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
        let (line, right) = render_awake(&s, &now, true, Path::new("/tmp/nope"));
        assert!(line.contains("1.23k"));
        // Mood was unparked 2026-05-08 (Chris) — the awake line now
        // surfaces both the mood icon AND the mood word. The earlier
        // assertion that "focused" was hidden reflected the parked
        // arrangement ; updated to assert the unparked behavior.
        assert!(line.contains("focused"), "mood word should be shown post-unpark");
        assert!(line.contains("🎯"), "mood icon should be shown post-unpark");
        assert!(!line.contains("💭"), "musings count is hidden");
        assert!(line.contains("✉️ 3"));
        assert!(line.contains("🤖"));
        assert!(!line.contains("🔬"), "no inventions row when count=0");
        // No fresh breadcrumb at /tmp/nope/.last_dispatch → right
        // segment is empty.
        assert!(right.is_empty(), "no breadcrumb expected for non-existent info dir");
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
        let (line, _right) = render_awake(&s, &now, false, Path::new("/tmp/nope"));
        assert!(line.contains("⚠"), "coherence false → mood glyph degraded");
    }

    #[test]
    fn right_align_pins_segment_to_column_edge() {
        // 80-col terminal, 10-col left, 20-col right ⇒ 50 spaces of gap.
        let left = "hello-left";       // 10 chars, width 10
        let right = "tools-segment-here20";   // 20 chars
        let line = right_align(left, right, 80);
        assert_eq!(visible_width(&line), 80, "rendered width fills terminal");
        assert!(line.starts_with(left), "left content stays on the left");
        assert!(line.ends_with(right), "right content hugs the right edge");
    }

    #[test]
    fn right_align_empty_right_returns_left_unchanged() {
        // No tool call ⇒ no padding (don't fill the bar with whitespace
        // just because we asked).
        let line = right_align("hello", "", 120);
        assert_eq!(line, "hello");
    }

    #[test]
    fn right_align_falls_back_to_two_space_gap_when_overflow() {
        // Left + right > cols ⇒ minimum 2-space gap, terminal wraps.
        let left = "a".repeat(50);
        let right = "b".repeat(50);
        let line = right_align(&left, &right, 80);
        // Gap is exactly 2 spaces between the two segments.
        let expected = format!("{}  {}", left, right);
        assert_eq!(line, expected);
    }

    #[test]
    fn right_align_handles_three_common_widths() {
        let left = "❤️ 82.42k 🎯 focused";
        let right = "🛠️  Tools.Bash";
        for cols in [80usize, 120, 160] {
            let line = right_align(left, right, cols);
            // Right segment must terminate the string.
            assert!(line.ends_with(right), "right segment must close at col {}", cols);
            // The line's visible width fills (or just-overflows by the
            // 2-space-floor case) the terminal — at common widths the
            // segment sums are well under, so we expect exact fill.
            assert_eq!(
                visible_width(&line),
                cols,
                "line should fill {}-col terminal, got width {}",
                cols, visible_width(&line)
            );
        }
    }

    #[test]
    fn visible_width_skips_ansi_csi_sequences() {
        // ESC [ 31 m … ESC [ 0 m — red + reset.
        let s = "\u{1B}[31mhello\u{1B}[0m";
        assert_eq!(visible_width(s), 5);
    }

    #[test]
    fn visible_width_counts_emoji_as_width_two() {
        assert_eq!(visible_width("❤️"), 2);   // heart + VS16 (VS counts 0)
        assert_eq!(visible_width("🛠️"), 2);   // hammer-and-wrench + VS16
        assert_eq!(visible_width("a❤️b"), 4); // 1 + 2 + 1
    }
}
