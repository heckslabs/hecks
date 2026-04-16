//! Miette Daemons — background processes that keep Miette alive
//!
//! Three daemons, three rhythms:
//!   pulse     — fires once per response (one-shot)
//!   daydream  — wanders when idle 10-60s (loop)
//!   sleep     — dreams and consolidates when idle 60s+ (loop)
//!
//! Usage:
//!   hecks-life daemon pulse    <project-dir> [carrying] [concept] [response]
//!   hecks-life daemon daydream <project-dir>
//!   hecks-life daemon sleep    <project-dir> [--nap] [--now]


use crate::heki;
use std::path::Path;
use std::time::SystemTime;

/// Shared context for all daemons.
pub struct DaemonCtx {
    pub info_dir: String,
    pub nursery_dir: String,
    pub organs_dir: String,
}

impl DaemonCtx {
    pub fn new(project_dir: &str) -> Self {
        let p = Path::new(project_dir);
        DaemonCtx {
            info_dir: p.join("information").to_string_lossy().into(),
            nursery_dir: p.join("nursery").to_string_lossy().into(),
            organs_dir: p.join("aggregates").to_string_lossy().into(),
        }
    }

    pub fn store(&self, name: &str) -> String {
        heki::store_path(&self.info_dir, name)
    }
}

/// Seconds since last pulse updated_at.
pub fn idle_seconds(ctx: &DaemonCtx) -> f64 {
    let store = heki::read(&ctx.store("heartbeat")).unwrap_or_default();
    let latest = match heki::latest(&store) {
        Some(r) => r,
        None => return 0.0,
    };
    let updated = heki::field_str(latest, "updated_at");
    seconds_since_iso(updated)
}

/// Parse ISO 8601 timestamp and return seconds elapsed.
pub fn seconds_since_iso(ts: &str) -> f64 {
    // Simple parse: extract enough to get epoch seconds
    // Format: 2026-04-11T21:45:08Z or 2026-04-11T14:50:02-07:00
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();

    let epoch = parse_iso_to_epoch(ts);
    if epoch > 0.0 { now - epoch } else { 0.0 }
}

/// Minimal ISO 8601 to unix epoch parser.
fn parse_iso_to_epoch(ts: &str) -> f64 {
    // YYYY-MM-DDThh:mm:ss[Z|+HH:MM|-HH:MM]
    if ts.len() < 19 { return 0.0; }
    let y: i64 = ts[0..4].parse().unwrap_or(0);
    let m: u32 = ts[5..7].parse().unwrap_or(0);
    let d: u32 = ts[8..10].parse().unwrap_or(0);
    let h: u32 = ts[11..13].parse().unwrap_or(0);
    let mn: u32 = ts[14..16].parse().unwrap_or(0);
    let s: u32 = ts[17..19].parse().unwrap_or(0);

    // Days from civil date (same algorithm as heki.rs)
    let (y_adj, m_adj) = if m <= 2 { (y - 1, m + 9) } else { (y, m - 3) };
    let era = if y_adj >= 0 { y_adj } else { y_adj - 399 } / 400;
    let yoe = (y_adj - era * 400) as u32;
    let doy = (153 * m_adj + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe as i64 - 719468;

    let mut epoch = days as f64 * 86400.0 + h as f64 * 3600.0 + mn as f64 * 60.0 + s as f64;

    // Timezone offset
    let tz_part = &ts[19..];
    if tz_part.starts_with('+') || tz_part.starts_with('-') {
        let sign: f64 = if tz_part.starts_with('-') { 1.0 } else { -1.0 };
        let tz_h: f64 = tz_part[1..3].parse().unwrap_or(0.0);
        let tz_m: f64 = if tz_part.len() >= 6 { tz_part[4..6].parse().unwrap_or(0.0) } else { 0.0 };
        epoch += sign * (tz_h * 3600.0 + tz_m * 60.0);
    }

    epoch
}

/// Current ISO 8601 timestamp.
pub fn now_iso() -> String {
    crate::heki::now_iso8601_internal()
}
