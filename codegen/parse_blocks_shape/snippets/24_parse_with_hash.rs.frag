/// Parse the inside of a `with: { ... }` hash into an ordered Vec of
/// `(key, ValueSpec)` pairs. Splitting respects nested parens (so
/// `default: "—,"` inside `from_pm(...)` doesn't split), at the cost
/// of not respecting string literals (matches the wider parser
/// surface : an author-supplied literal containing a comma would be
/// surfaced as parity drift).
fn parse_with_hash(body: &str) -> Vec<(String, ValueSpec)> {
    let mut out: Vec<(String, ValueSpec)> = Vec::new();
    for raw_entry in split_top_level_commas(body) {
        let entry = raw_entry.trim().trim_end_matches(',').trim();
        if entry.is_empty() { continue; }
        // `key: value` where key is a bare ident or a quoted string,
        // and value is a literal (string / number) or a sentinel call
        // `from_event(...)` / `from_pm(...)`. A trailing comma after
        // the last entry is tolerated.
        let colon = match entry.find(':') {
            Some(p) => p,
            None => continue,
        };
        // Skip cases where the `:` is part of `=>` or starts a Symbol
        // literal value — for now we only accept the kwarg-shorthand
        // form `key: value`. Hash-rocket form is filed as a follow-up
        // (no PM in the corpus uses it for `with:`).
        let key_raw = entry[..colon].trim();
        let val_raw = entry[colon + 1..].trim();
        let key = key_raw
            .trim_matches(|c| c == '"' || c == '\'' || c == ':')
            .to_string();
        if key.is_empty() { continue; }
        if let Some(spec) = parse_value_spec(val_raw) {
            out.push((key, spec));
        }
    }
    out
}

