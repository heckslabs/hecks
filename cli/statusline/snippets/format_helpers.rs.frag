
/// Format beat count : ≥1M → "X.XXm" ; ≥1k → "X.XXk" ; else raw.
fn format_beats(b: i64) -> String {
    if b >= 1_000_000 {
        format!("{:.2}m", (b as f64) / 1_000_000.0)
    } else if b >= 1_000 {
        format!("{:.2}k", (b as f64) / 1_000.0)
    } else {
        b.to_string()
    }
}

/// Read `<info>/.last_dispatch` (two lines : cmd, unix_seconds). If
/// the timestamp is < 30s old, return Some(cmd) ; otherwise None.
fn read_last_dispatch(info: &Path) -> Option<String> {
    let content = fs::read_to_string(info.join(".last_dispatch")).ok()?;
    let mut lines = content.lines();
    let cmd = lines.next()?.to_string();
    let ts: i64 = lines.next()?.parse().ok()?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .ok()?;
    if cmd.is_empty() || (now - ts) >= 30 {
        return None;
    }
    Some(cmd)
}
