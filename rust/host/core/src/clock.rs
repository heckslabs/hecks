//! The wall clock, read once the same way everywhere.

/// Whole seconds since the Unix epoch; 0 if the system clock reads before it.
pub fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs() as i64)
}

/// The current instant in ISO 8601 UTC, matching Ruby's `Time.now.utc.iso8601`: the rendering
/// a journal step's `occurred_at` and a role assignment's `starts_at` both carry.
pub fn iso8601_now() -> String {
    iso_utc(unix_now().max(0) as u64)
}

/// Epoch seconds as an ISO 8601 UTC instant, `YYYY-MM-DDTHH:MM:SSZ`.
pub fn iso_utc(secs: u64) -> String {
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let (y, mo, d) = civil_from_days(days as i64);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{m:02}:{s:02}Z")
}

/// Epoch seconds of an ISO 8601 UTC instant (`YYYY-MM-DDTHH:MM:SSZ`, optional fractional
/// seconds, which are dropped); `None` for anything else, an offset other than `Z` included.
pub fn parse_iso_utc(text: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    if bytes.len() < 20 || !text.is_ascii() || *bytes.last()? != b'Z' {
        return None;
    }
    let number = |range: std::ops::Range<usize>| -> Option<i64> {
        let digits = text.get(range)?;
        digits
            .bytes()
            .all(|b| b.is_ascii_digit())
            .then(|| digits.parse().ok())
            .flatten()
    };
    let separators_ok = bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes[10] == b'T'
        && bytes[13] == b':'
        && bytes[16] == b':';
    let fraction = &text[19..text.len() - 1];
    let fraction_ok = fraction.is_empty()
        || (fraction.starts_with('.')
            && fraction.len() > 1
            && fraction[1..].bytes().all(|b| b.is_ascii_digit()));
    if !separators_ok || !fraction_ok {
        return None;
    }
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    let in_range = (1..=12).contains(&month)
        && (1..=days_in_month(year, month)).contains(&day)
        && hour < 24
        && minute < 60
        && second < 60;
    in_range
        .then(|| days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second)
}

const fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

// Howard Hinnant's days-from-civil algorithm, inverted -- avoids
// pulling in a full date/time crate for one timestamp format.
const fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

// The inverse of `civil_from_days`: whole days since 1970-01-01 for a proleptic Gregorian date.
const fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = if month > 2 { month - 3 } else { month + 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_utc_and_parse_iso_utc_are_inverses_across_leap_days_and_century_years() {
        for secs in [
            0_u64,
            951_782_400,   // 2000-02-29, a leap day in a 400-year
            1_078_012_800, // 2004-02-29
            4_107_542_400, // 2100-03-01, 2100 is not a leap year
            1_792_000_000,
            4_102_444_799,
        ] {
            assert_eq!(parse_iso_utc(&iso_utc(secs)), Some(secs as i64), "{secs}");
        }
        assert_eq!(iso_utc(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(parse_iso_utc("1970-01-01T00:00:00Z"), Some(0));
    }

    #[test]
    fn parse_iso_utc_drops_fractional_seconds_and_refuses_everything_else() {
        assert_eq!(
            parse_iso_utc("2026-10-22T12:00:00.789Z"),
            parse_iso_utc("2026-10-22T12:00:00Z")
        );
        for bad in [
            "",
            "tomorrow",
            "2026-10-22",
            "2026-10-22T12:00:00",
            "2026-10-22T12:00:00+00:00",
            "2026-10-22 12:00:00Z",
            "2026-13-01T00:00:00Z",
            "2026-02-29T00:00:00Z",
            "2026-00-10T00:00:00Z",
            "2026-10-22T24:00:00Z",
            "2026-10-22T12:60:00Z",
            "2026-10-22T12:00:60Z",
            "2026-10-22T12:00:00.Z",
            "2026-10-22T12:00:00.1xZ",
            "+026-10-22T12:00:00Z",
            "2026-10-22T12:00:0éZ",
        ] {
            assert_eq!(parse_iso_utc(bad), None, "{bad:?}");
        }
    }
}
