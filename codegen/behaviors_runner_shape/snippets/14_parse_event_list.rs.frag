/// Parse the value side of `expect emits: [E1, E2, E3]` from the
/// behaviors IR (which carries the source-token form). Strips brackets
/// and splits on commas; tolerates surrounding whitespace and quoted
/// strings. An empty list (`[]`) returns an empty Vec.
fn parse_event_list(raw: &str) -> Vec<String> {
    let trimmed = raw.trim();
    let inner = trimmed
        .strip_prefix('[').unwrap_or(trimmed)
        .strip_suffix(']').unwrap_or(trimmed);
    if inner.trim().is_empty() { return Vec::new(); }
    inner.split(',')
        .map(|s| s.trim().trim_matches('"').trim_matches('\'').to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

