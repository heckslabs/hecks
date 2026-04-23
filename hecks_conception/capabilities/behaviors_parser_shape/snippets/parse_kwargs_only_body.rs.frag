// Snippet: parse_kwargs_only body. Parses kwargs after a leading
// keyword (`input` / `expect`).
    let mut out = BTreeMap::new();
    let Some(start) = line.find(keyword) else { return out; };
    let body = line[start + keyword.len()..].trim();
    if body.is_empty() { return out; }
    for part in split_top_level_commas(body) {
        if let Some((k, v)) = split_kwarg(part.trim()) {
            out.insert(k, v);
        }
    }
    out
