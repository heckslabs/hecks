/// Parse one with-value into a ValueSpec. Three forms :
///
///   "literal"                              → ValueSpec::Literal
///   from_event(:name)                       → FromEvent { default: None }
///   from_event(:name, default: "x")         → FromEvent { default: Some("x") }
///   from_pm(:name)                          → FromPm   { default: None }
///   from_pm(:name, default: "—")            → FromPm   { default: Some("—") }
///
/// Numeric / bare-ident literals are accepted and stringified ; that
/// matches the wider parser convention (canonical IR carries scalars
/// as strings). Returns None on malformed input.
fn parse_value_spec(raw: &str) -> Option<ValueSpec> {
    let s = raw.trim();
    if s.starts_with("from_event") {
        let (name, default) = parse_sentinel_args(s, "from_event")?;
        Some(ValueSpec::FromEvent { name, default })
    } else if s.starts_with("from_pm") {
        let (name, default) = parse_sentinel_args(s, "from_pm")?;
        Some(ValueSpec::FromPm { name, default })
    } else if s.starts_with('"') || s.starts_with('\'') {
        let value = extract_string(s).unwrap_or_default();
        Some(ValueSpec::Literal { value })
    } else {
        // Bare ident / number / symbol — stringify the trimmed token.
        let token = s.trim_end_matches(',').trim().to_string();
        if token.is_empty() {
            return None;
        }
        Some(ValueSpec::Literal { value: token })
    }
}

