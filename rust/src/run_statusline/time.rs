//! [antibody-exempt: rust/src/run_statusline/ — module of the Statuslinen//!  runner ; see mod.rs for the full kernel-floor rationale. Retiresn//!  with mod.rs under i78 when the specializer regenerates from an//!  meta-shape.]n//!n//! Wall-clock time helper + heart-glyph animation. Captured at the
//! top of `run()` so all downstream rendering shares one timestamp.


pub(super) struct Now {
    pub(super) secs: u64,
    pub(super) nanos_total: u128,
}

impl Now {
    pub(super) fn wall_clock() -> Self {
        let dur = crate::clock::now_duration();
        Self {
            secs: dur.as_secs(),
            nanos_total: dur.as_nanos(),
        }
    }
}

const HEARTS: [&str; 2] = ["🖤", "❤️"];

/// 333ms phase from wall-clock nanoseconds — odd bucket count between
/// consecutive 1Hz polls guarantees parity flips. Same formula
/// statusline-command.sh used post-PR e0abc604.
pub(super) fn heart_glyph(now: &Now) -> &'static str {
    let phase = (now.nanos_total / 333_000_000) % 2;
    HEARTS[phase as usize]
}
