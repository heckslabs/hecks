//! StoreHouse stdout logger — i622
//!
//! [antibody-exempt: rust/src/runtime/storehouse_log.rs — kernel-floor
//!  sibling of rust/src/runtime/mod.rs. Owns the one-line stdout
//!  records that mod.rs's dispatch path emits ; lives in Rust because
//!  it touches stdout from the runtime hot path and reads the
//!  STOREHOUSE_LOG env var once at process start. Retires alongside
//!  runtime/mod.rs's existing kernel-floor exemption when the
//!  framework-wide kernel-hook registry absorbs the dispatch
//!  surface — at that point the logger moves to a bluebook-defined
//!  `:log` adapter family.]
//!
//! One-line stdout records for every dispatch, event, cascade step,
//! and policy reaction. Level gated by the `STOREHOUSE_LOG` env var
//! read once at process start (`init`/`level`).
//!
//! Levels :
//!   - `quiet`   — dispatch entry + policy reactions only
//!   - `normal`  — dispatch + event + cascade + policy   (default)
//!   - `verbose` — normal + per-attribute trace
//!
//! Usage :
//!   storehouse_log::dispatch_entry("Tools::ShellTool.Bash", "abc123", Some("run echo"));
//!   storehouse_log::event_emitted("ShellTool", "BashRan", "abc123");
//!   storehouse_log::cascade_step("Cascade.RecordResult", "abc123", true);
//!   storehouse_log::policy_reaction("OnBashRan", "ShellTool", "BashRan", "abc123", "Cascade.RecordResult");
//!   storehouse_log::attribute_trace("ShellTool", "abc123", "shell_command", "echo hi");
//!   storehouse_log::mcp_stderr_line("storehouse", "server listening on stdio");
//!
//! Lines are written via `println!` so the runtime's stdout is the
//! single audit stream. See `hecks_conception/inbox/i622.md` for the
//! design and `i613.md` for the envelope shape this record reflects.

use std::sync::OnceLock;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum LogLevel {
    Quiet,
    Normal,
    Verbose,
}

static LEVEL: OnceLock<LogLevel> = OnceLock::new();

/// Resolve and cache the log level from `STOREHOUSE_LOG`. Defaults to
/// `Normal` when unset or unrecognised. Idempotent : first call wins,
/// subsequent calls return the cached value (matching the i622 design
/// note that the level is read once at process start).
pub fn level() -> LogLevel {
    *LEVEL.get_or_init(|| match std::env::var("STOREHOUSE_LOG").ok().as_deref() {
        Some("quiet")   => LogLevel::Quiet,
        Some("verbose") => LogLevel::Verbose,
        _               => LogLevel::Normal,
    })
}

/// Test-only override. Resets the cached level. Not exposed to callers
/// outside the runtime — only `#[cfg(test)]` paths in this crate touch
/// it. Safe to call before any logging happens.
#[cfg(test)]
pub fn set_level_for_test(new_level: LogLevel) {
    // OnceLock has no public reset ; we read and ignore. Tests that
    // need to flip levels run with a single fixed env value per
    // process — the dedicated cargo-test integration spawns
    // subprocesses (see `rust/tests/storehouse_log_test.rs`).
    let _ = LEVEL.set(new_level);
}

/// Surface 1 — dispatch entry. Printed when a top-level command enters
/// the runtime. `description` is optional (the human-readable label
/// from the command declaration, when known).
pub fn dispatch_entry(fqn: &str, id: &str, description: Option<&str>) {
    if level() == LogLevel::Quiet || level() == LogLevel::Normal || level() == LogLevel::Verbose {
        let desc = description
            .map(|d| format!(" \"{}\"", d))
            .unwrap_or_default();
        println!("[{}] dispatch {}#{}{}", now_iso8601(), fqn, id, desc);
    }
}

/// Surface 2 — event emission. Printed when a dispatch yields its
/// event. Suppressed at `Quiet`.
pub fn event_emitted(aggregate: &str, event_name: &str, id: &str) {
    if level() == LogLevel::Normal || level() == LogLevel::Verbose {
        println!("[{}] event {}.{}#{}", now_iso8601(), aggregate, event_name, id);
    }
}

/// Surface 3 — cascade chain step. Printed when a cascade dispatch
/// fires (claude_tool result_into, policy trigger, PM dispatch, etc.).
/// `ok` reflects the cascade outcome (`true` on success, `false` on
/// dispatch error). Suppressed at `Quiet`.
pub fn cascade_step(fqn: &str, id: &str, ok: bool) {
    if level() == LogLevel::Normal || level() == LogLevel::Verbose {
        println!("[{}] cascade {}#{} ok={}", now_iso8601(), fqn, id, ok);
    }
}

/// Surface 4 — policy reaction. Printed when a policy fires in response
/// to an event and dispatches a follow-up command. Visible at every
/// level (policy chains are too important to silence even at `Quiet`).
pub fn policy_reaction(
    policy_name: &str,
    aggregate: &str,
    event_name: &str,
    id: &str,
    dispatched_command: &str,
) {
    if level() == LogLevel::Quiet || level() == LogLevel::Normal || level() == LogLevel::Verbose {
        println!(
            "[{}] policy {} on {}.{}#{} -> {}",
            now_iso8601(), policy_name, aggregate, event_name, id, dispatched_command
        );
    }
}

/// Surface 5 — per-attribute trace. Only printed at `Verbose`.
/// One line per attribute set into aggregate state during a dispatch.
pub fn attribute_trace(aggregate: &str, id: &str, attr: &str, value: &str) {
    if level() == LogLevel::Verbose {
        // Truncate noisy values so the verbose trace stays one-line.
        let v_trimmed = if value.len() > 80 {
            format!("{}…", &value[..80])
        } else {
            value.to_string()
        };
        println!(
            "[{}] attr {}#{} {}={}",
            now_iso8601(), aggregate, id, attr, v_trimmed
        );
    }
}

/// MCP child stderr — one log line per line captured from a `:mcp`
/// adapter's child process. Visible at every level (these are
/// substrate-level diagnostics that operators expect to see when an
/// MCP server misbehaves). `server` is the resolved server name
/// (e.g. `storehouse`) ; `line` is the raw stderr line, trimmed.
pub fn mcp_stderr_line(server: &str, line: &str) {
    println!("[{}] [mcp:{}] {}", now_iso8601(), server, line);
}

/// RFC-3339 / ISO-8601 timestamp with seconds precision, UTC. Hand-
/// rolled to avoid a chrono dependency — Cargo.toml stays minimal.
/// Produces `YYYY-MM-DDTHH:MM:SSZ`. Public for callers that want to
/// emit ad-hoc lines on the same stream with matching timestamps.
pub fn now_iso8601() -> String {
    // wasm-safe clock (i630) — raw SystemTime::now() panics
    // "time not implemented" on wasm32 (CF Worker). dispatch_entry
    // runs on every dispatch, so the worker hit this on every POST.
    let secs = crate::heki::now_duration().as_secs();
    format_iso8601(secs)
}

/// Format a Unix epoch second count as ISO-8601 UTC. Splits the
/// seconds into Y-M-D H:M:S using the civil-from-days algorithm
/// (Howard Hinnant, MIT-licensed public algorithm) so we don't pull
/// chrono just for one timestamp surface.
fn format_iso8601(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let s = (secs % 86_400) as u32;
    let (year, month, day) = civil_from_days(days);
    let hour = s / 3600;
    let min = (s % 3600) / 60;
    let sec = s % 60;
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hour, min, sec
    )
}

/// Convert Unix epoch days (offset from 1970-01-01) into (year, month,
/// day). Adapted from Howard Hinnant's `civil_from_days`. Stable for
/// every date between 0000-03-01 and ~5879611-07-11, which is well
/// past anything this logger will encounter.
fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719_468; // shift epoch to 0000-03-01
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u32; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe as i32 + (era as i32) * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso8601_unix_epoch_zero() {
        assert_eq!(format_iso8601(0), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn iso8601_known_date() {
        // 2026-05-14T18:42:01Z  =  1778784121 epoch
        // (sanity-checked against `date -u -d @1778784121`)
        assert_eq!(format_iso8601(1_778_784_121), "2026-05-14T18:42:01Z");
    }

    #[test]
    fn iso8601_leap_day() {
        // 2024-02-29T00:00:00Z = 1709164800
        assert_eq!(format_iso8601(1_709_164_800), "2024-02-29T00:00:00Z");
    }
}
