//! cron_schedule — the pure 5-field cron-expression matcher for
//! `driving on cron` Drivers fired by `storehouse drive`.
//!
//! Where `drive_scheduler` is the pure tick-counter for the INTERVAL kind,
//! this is its sibling for the CRON kind : given a 5-field cron string and a
//! wall-clock instant, decide whether the expression is DUE at that minute.
//! Pure + heavily table-tested : no Runtime, no IO, no live clock — the
//! caller (`run_drive`) supplies `now` (from `crate::clock::now_duration`,
//! pinnable via `HECKS_NOW` for deterministic tests).
//!
//! Supported syntax per field (minute hour day-of-month month day-of-week) :
//!   `*`      — any value
//!   `*/N`    — every N (step over the field's full range)
//!   `N`      — exact value
//!   `N-M`    — inclusive range
//!   `A,B,C`  — comma list (each element may itself be `*`, `N`, `N-M`, `*/N`,
//!              or a stepped range `N-M/S`)
//! Field ranges : minute 0-59, hour 0-23, dom 1-31, month 1-12, dow 0-6
//! (Sunday = 0 ; 7 is accepted as Sunday too). Standard cron day-or semantics :
//! when BOTH day-of-month and day-of-week are restricted (neither `*`), the
//! match is their UNION ; otherwise the AND of all five fields.
//!
//! Usage :
//!   let due = cron_schedule::is_due("*/5 * * * *",
//!                                   crate::clock::now_duration().as_secs());
//!   // true on minutes 0,5,10,... of every hour.

/// Whether `cron_expr` matches the wall-clock minute containing `now_secs`
/// (Unix epoch seconds, UTC). A malformed expression never matches (returns
/// false) — the daemon treats an unparseable cron as "never due" rather than
/// panicking the whole drive loop.
pub fn is_due(cron_expr: &str, now_secs: u64) -> bool {
    let fields: Vec<&str> = cron_expr.split_whitespace().collect();
    if fields.len() != 5 {
        return false;
    }
    let (minute, hour, dom, month, dow) = civil_fields(now_secs);

    let min_ok = field_matches(fields[0], minute, 0, 59);
    let hour_ok = field_matches(fields[1], hour, 0, 23);
    let mon_ok = field_matches(fields[3], month, 1, 12);
    if !(min_ok && hour_ok && mon_ok) {
        return false;
    }

    // Day-or semantics : if both dom and dow are restricted, match the UNION ;
    // otherwise AND them with the rest (a `*` field is always satisfied).
    let dom_restricted = fields[2] != "*";
    let dow_restricted = fields[4] != "*";
    let dom_ok = field_matches(fields[2], dom, 1, 31);
    let dow_ok = dow_field_matches(fields[4], dow);
    if dom_restricted && dow_restricted {
        dom_ok || dow_ok
    } else {
        dom_ok && dow_ok
    }
}

/// The minute-bucket an instant falls in : `now_secs / 60`. The drive daemon
/// keys its per-handler last-fired mark on this so a sub-minute poll fires a
/// due expression at most once per minute. Exposed as the single source of the
/// minute boundary so the daemon and the tests agree on it.
pub fn minute_bucket(now_secs: u64) -> u64 {
    now_secs / 60
}

/// Whole live firing decision for one cron handler, kept pure so the
/// minute-dedup — the key correctness concern — is unit-testable without the
/// daemon's infinite poll loop. Fires iff the expression is DUE at `now_secs`
/// AND this handler has not already fired in the current minute bucket.
/// `last_fired_minute` is the daemon's recorded bucket for this handler (None
/// = never fired). Returns the new bucket to record when it decides to fire,
/// so the caller updates its map in lock-step :
///   if let Some(min) = should_fire(expr, now, last) { map.insert(id, min); .. }
pub fn should_fire(cron_expr: &str, now_secs: u64, last_fired_minute: Option<u64>) -> Option<u64> {
    if !is_due(cron_expr, now_secs) {
        return None;
    }
    let bucket = minute_bucket(now_secs);
    if last_fired_minute == Some(bucket) {
        return None; // already fired this minute — dedup the sub-minute poll
    }
    Some(bucket)
}

/// Match a single cron field against a value, given that field's inclusive
/// `[lo, hi]` range. Splits on commas ; each element is matched independently
/// and the field matches if ANY element does.
fn field_matches(field: &str, value: u32, lo: u32, hi: u32) -> bool {
    field.split(',').any(|elem| element_matches(elem.trim(), value, lo, hi))
}

/// Day-of-week wrapper : normalises both the cron `7` (Sunday) and the
/// computed dow so 7 and 0 are interchangeable, then matches over 0-6.
fn dow_field_matches(field: &str, dow: u32) -> bool {
    field.split(',').any(|raw| {
        let elem = raw.trim();
        // `7` anywhere is Sunday : a literal 7 element matches dow 0.
        if elem == "7" && dow == 0 {
            return true;
        }
        element_matches(elem, dow, 0, 6)
    })
}

/// Match one non-comma element : `*`, `*/N`, `N`, `N-M`, or `N-M/S`.
fn element_matches(elem: &str, value: u32, lo: u32, hi: u32) -> bool {
    if elem == "*" {
        return true;
    }
    // Step form : `<base>/<step>` where base is `*` or a range.
    if let Some((base, step_s)) = elem.split_once('/') {
        let step: u32 = match step_s.parse() {
            Ok(s) if s > 0 => s,
            _ => return false,
        };
        let (rlo, rhi) = match range_bounds(base, lo, hi) {
            Some(b) => b,
            None => return false,
        };
        return value >= rlo && value <= rhi && (value - rlo).is_multiple_of(step);
    }
    // Range form : `N-M`.
    if let Some((a, b)) = elem.split_once('-') {
        return match (a.parse::<u32>(), b.parse::<u32>()) {
            (Ok(a), Ok(b)) => value >= a && value <= b,
            _ => false,
        };
    }
    // Exact value.
    matches!(elem.parse::<u32>(), Ok(n) if n == value)
}

/// The inclusive bounds a step's base spans : `*` -> the field range ;
/// `N-M` -> that range ; bare `N` -> `[N, hi]` (cron's `N/step` reading).
fn range_bounds(base: &str, lo: u32, hi: u32) -> Option<(u32, u32)> {
    if base == "*" {
        return Some((lo, hi));
    }
    if let Some((a, b)) = base.split_once('-') {
        return Some((a.parse().ok()?, b.parse().ok()?));
    }
    let n: u32 = base.parse().ok()?;
    Some((n, hi))
}

/// Decompose Unix epoch seconds (UTC) into the five cron fields :
/// (minute, hour, day-of-month, month, day-of-week). Day-of-week is 0=Sunday
/// .. 6=Saturday. Reuses the Euclidean affine civil-date algorithm that
/// `clock::now_iso8601_internal` uses, so the calendar maths stays consistent.
fn civil_fields(secs: u64) -> (u32, u32, u32, u32, u32) {
    let day_secs = (secs % 86400) as u32;
    let hour = day_secs / 3600;
    let minute = (day_secs % 3600) / 60;

    let z = (secs / 86400) as i64 + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };

    // Day-of-week : 1970-01-01 (epoch day 0) was a Thursday (=4).
    let dow = (((secs / 86400) as i64 + 4).rem_euclid(7)) as u32;

    (minute, hour, day, month, dow)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Reference instants (UTC), confirmed against the civil-date algorithm :
    //   1718928000 = 2024-06-21 00:00:00 UTC (a Friday, dow=5)
    //   1718928300 = 2024-06-21 00:05:00 UTC
    //   1718929800 = 2024-06-21 00:30:00 UTC
    //   1718931600 = 2024-06-21 01:00:00 UTC
    const FRI_0000: u64 = 1718928000;
    const FRI_0005: u64 = 1718928300;
    const FRI_0030: u64 = 1718929800;
    const FRI_0100: u64 = 1718931600;

    #[test]
    fn civil_fields_decomposes_correctly() {
        assert_eq!(civil_fields(FRI_0000), (0, 0, 21, 6, 5)); // Fri 2024-06-21 00:00
        assert_eq!(civil_fields(FRI_0030), (30, 0, 21, 6, 5));
        assert_eq!(civil_fields(FRI_0100), (0, 1, 21, 6, 5));
        // 1970-01-01 00:00:00 was a Thursday (dow 4).
        assert_eq!(civil_fields(0), (0, 0, 1, 1, 4));
    }

    #[test]
    fn star_matches_every_minute() {
        assert!(is_due("* * * * *", FRI_0000));
        assert!(is_due("* * * * *", FRI_0005));
        assert!(is_due("* * * * *", FRI_0030));
    }

    #[test]
    fn step_every_five_minutes() {
        assert!(is_due("*/5 * * * *", FRI_0000)); // minute 0
        assert!(is_due("*/5 * * * *", FRI_0005)); // minute 5
        assert!(is_due("*/5 * * * *", FRI_0030)); // minute 30
        // minute 1,2,3,4 must NOT match */5.
        assert!(!is_due("*/5 * * * *", FRI_0000 + 60));
        assert!(!is_due("*/5 * * * *", FRI_0000 + 180));
    }

    #[test]
    fn exact_minute_and_hour() {
        assert!(is_due("0 1 * * *", FRI_0100));   // 01:00
        assert!(!is_due("0 1 * * *", FRI_0000));  // 00:00 — hour mismatch
        assert!(!is_due("30 0 * * *", FRI_0000)); // minute mismatch
        assert!(is_due("30 0 * * *", FRI_0030));
    }

    #[test]
    fn comma_list_of_minutes() {
        assert!(is_due("0,30 * * * *", FRI_0000));
        assert!(is_due("0,30 * * * *", FRI_0030));
        assert!(!is_due("0,30 * * * *", FRI_0005));
    }

    #[test]
    fn range_of_minutes() {
        assert!(is_due("0-10 * * * *", FRI_0000));
        assert!(is_due("0-10 * * * *", FRI_0005));
        assert!(!is_due("0-10 * * * *", FRI_0030)); // 30 outside 0-10
    }

    #[test]
    fn stepped_range() {
        // 0-30/10 -> minutes 0,10,20,30.
        assert!(is_due("0-30/10 * * * *", FRI_0000));
        assert!(is_due("0-30/10 * * * *", FRI_0030));
        assert!(!is_due("0-30/10 * * * *", FRI_0005));
    }

    #[test]
    fn month_and_dom_fields() {
        assert!(is_due("* * 21 6 *", FRI_0000));   // 21st June
        assert!(!is_due("* * 22 6 *", FRI_0000));  // 22nd — dom mismatch
        assert!(!is_due("* * 21 7 *", FRI_0000));  // July — month mismatch
    }

    #[test]
    fn day_of_week_field() {
        assert!(is_due("* * * * 5", FRI_0000));  // Friday
        assert!(!is_due("* * * * 1", FRI_0000)); // Monday
        // Sunday accepted as both 0 and 7. 1718841600 = 2024-06-20? verify Sunday:
        // 2024-06-23 00:00 UTC = 1719100800, a Sunday (dow 0).
        let sunday = 1719100800u64;
        assert_eq!(civil_fields(sunday).4, 0);
        assert!(is_due("* * * * 0", sunday));
        assert!(is_due("* * * * 7", sunday));
    }

    #[test]
    fn day_or_semantics_union_when_both_restricted() {
        // dom=21 OR dow=1(Mon). On Fri the 21st : dom matches, dow does not ->
        // union is true.
        assert!(is_due("* * 21 * 1", FRI_0000));
        // dom=22 OR dow=5(Fri). On Fri the 21st : dom no, dow yes -> union true.
        assert!(is_due("* * 22 * 5", FRI_0000));
        // dom=22 OR dow=1. Neither matches Fri the 21st -> false.
        assert!(!is_due("* * 22 * 1", FRI_0000));
    }

    #[test]
    fn dom_and_dow_anded_when_one_is_star() {
        // dom=21, dow=* -> plain AND ; matches on the 21st.
        assert!(is_due("* * 21 * *", FRI_0000));
        // dom=*, dow=5 -> AND ; matches on Friday.
        assert!(is_due("* * * * 5", FRI_0000));
        // dom=22, dow=* -> AND ; 22 != 21 -> false (NOT union with the * dow).
        assert!(!is_due("* * 22 * *", FRI_0000));
    }

    #[test]
    fn malformed_never_matches() {
        assert!(!is_due("* * * *", FRI_0000));        // 4 fields
        assert!(!is_due("* * * * * *", FRI_0000));    // 6 fields
        assert!(!is_due("", FRI_0000));               // empty
        assert!(!is_due("*/0 * * * *", FRI_0000));    // zero step
        assert!(!is_due("abc * * * *", FRI_0000));    // non-numeric
    }

    #[test]
    fn should_fire_dedups_within_a_minute_then_refires_next_match() {
        // Simulate the `storehouse drive` poll loop : poll every 15s across a
        // "*/5 * * * *" handler. The handler must fire ONCE when minute 0
        // arrives, stay silent for the rest of that minute despite repeated
        // due-polls, and fire again only when the NEXT matching minute (5)
        // arrives. `last` mirrors the daemon's recorded minute bucket.
        let expr = "*/5 * * * *";
        let mut last: Option<u64> = None;
        let mut fires: Vec<u64> = Vec::new();

        // Poll the whole 00:00:00 minute at 15s cadence (4 polls). All are
        // `is_due` (minute 0 matches */5) but only the FIRST should fire.
        for sec in [0u64, 15, 30, 45] {
            if let Some(bucket) = should_fire(expr, FRI_0000 + sec, last) {
                last = Some(bucket);
                fires.push(FRI_0000 + sec);
            }
        }
        assert_eq!(fires, vec![FRI_0000], "fires exactly once in minute 0");

        // Minute 1-4 : NOT due (*/5), so no fire regardless of poll.
        for min in 1..=4u64 {
            assert!(should_fire(expr, FRI_0000 + min * 60, last).is_none());
        }

        // Minute 5 : due again, new bucket -> fires once more.
        let m5 = FRI_0000 + 5 * 60;
        assert!(should_fire(expr, m5, last).is_some(), "refires at minute 5");
        if let Some(bucket) = should_fire(expr, m5, last) {
            last = Some(bucket);
        }
        // ... and dedups within minute 5 too.
        assert!(should_fire(expr, m5 + 30, last).is_none());
    }

    #[test]
    fn should_fire_skips_non_matching_minutes_entirely() {
        // "30 * * * *" fires at minute 30 of every hour. Polling minute 0 must
        // never fire ; minute 30 fires once.
        let expr = "30 * * * *";
        assert!(should_fire(expr, FRI_0000, None).is_none());      // minute 0
        assert!(should_fire(expr, FRI_0030, None).is_some());      // minute 30
        // Once fired, the same minute won't refire.
        let b = should_fire(expr, FRI_0030, None).unwrap();
        assert!(should_fire(expr, FRI_0030 + 20, Some(b)).is_none());
    }

    #[test]
    fn minute_bucket_is_floor_division() {
        assert_eq!(minute_bucket(FRI_0000), FRI_0000 / 60);
        assert_eq!(minute_bucket(FRI_0000 + 59), FRI_0000 / 60); // same minute
        assert_eq!(minute_bucket(FRI_0000 + 60), FRI_0000 / 60 + 1); // next minute
    }

    #[test]
    fn realistic_combined_expression() {
        // "30 0 21 6 *" — 00:30 on June 21st, any weekday.
        assert!(is_due("30 0 21 6 *", FRI_0030));
        assert!(!is_due("30 0 21 6 *", FRI_0000)); // minute 0, not 30
        assert!(!is_due("30 0 21 6 *", FRI_0100)); // hour 1, not 0
    }
}
