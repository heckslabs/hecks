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
