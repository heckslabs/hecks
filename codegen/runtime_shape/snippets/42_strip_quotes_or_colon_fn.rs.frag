
/// i551 — strip the surrounding shape a hecksagon-options value
/// carries from `parse_options`. String literals come through as
/// `"\"Tools.Bash\""` (raw source token, quotes included) ; symbols
/// come through as `":bash"` (leading colon kept). Both forms need
/// to be reduced to their bare identifier before matching against
/// runtime targets / dispatcher tool names. Whitespace is trimmed
/// because parse_options preserves it from the source.
fn strip_quotes_or_colon(raw: &str) -> String {
    let t = raw.trim();
    if t.len() >= 2 && t.starts_with('"') && t.ends_with('"') {
        return t[1..t.len() - 1].to_string();
    }
    if let Some(rest) = t.strip_prefix(':') {
        return rest.to_string();
    }
    t.to_string()
}
