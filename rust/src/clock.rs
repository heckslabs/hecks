#[cfg(not(target_arch = "wasm32"))]
use std::time::SystemTime;

pub fn now_duration() -> std::time::Duration {
    if let Ok(pin) = std::env::var("HECKS_NOW") {
        if let Ok(secs) = pin.trim().parse::<u64>() {
            return std::time::Duration::from_secs(secs);
        }
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
    }
    #[cfg(target_arch = "wasm32")]
    {
        let ms = worker::Date::now().as_millis();
        std::time::Duration::from_millis(ms)
    }
}

pub fn now_iso8601_internal() -> String {
    let dur = now_duration();
    let secs = dur.as_secs();

    let mut days = (secs / 86400) as i64;
    let day_secs = (secs % 86400) as u32;
    let hours = day_secs / 3600;
    let mins = (day_secs % 3600) / 60;
    let s = day_secs % 60;

    days += 719468;
    let era = if days >= 0 { days } else { days - 146096 } / 146097;
    let doe = (days - era * 146097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y, m, d, hours, mins, s
    )
}

pub fn now_iso() -> String {
    now_iso8601_internal()
}

pub fn seconds_since_iso(ts: &str) -> f64 {
    let now = now_duration().as_secs_f64();
    let epoch = parse_iso_to_epoch(ts);
    if epoch > 0.0 {
        now - epoch
    } else {
        0.0
    }
}

fn parse_iso_to_epoch(ts: &str) -> f64 {
    if ts.len() < 19 {
        return 0.0;
    }
    let y: i64 = ts[0..4].parse().unwrap_or(0);
    let m: u32 = ts[5..7].parse().unwrap_or(0);
    let d: u32 = ts[8..10].parse().unwrap_or(0);
    let h: u32 = ts[11..13].parse().unwrap_or(0);
    let mn: u32 = ts[14..16].parse().unwrap_or(0);
    let s: u32 = ts[17..19].parse().unwrap_or(0);
    let (y_adj, m_adj) = if m <= 2 { (y - 1, m + 9) } else { (y, m - 3) };
    let era = if y_adj >= 0 { y_adj } else { y_adj - 399 } / 400;
    let yoe = (y_adj - era * 400) as u32;
    let doy = (153 * m_adj + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe as i64 - 719468;
    let mut epoch = days as f64 * 86400.0 + h as f64 * 3600.0 + mn as f64 * 60.0 + s as f64;
    let tz_part = &ts[19..];
    if tz_part.starts_with('+') || tz_part.starts_with('-') {
        let sign: f64 = if tz_part.starts_with('-') { 1.0 } else { -1.0 };
        let tz_h: f64 = tz_part[1..3].parse().unwrap_or(0.0);
        let tz_m: f64 = if tz_part.len() >= 6 {
            tz_part[4..6].parse().unwrap_or(0.0)
        } else {
            0.0
        };
        epoch += sign * (tz_h * 3600.0 + tz_m * 60.0);
    }
    epoch
}
