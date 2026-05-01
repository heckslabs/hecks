// Snippet: parse_kwarg_tail body. Parses kwargs that follow a
// positional first arg (everything after the first comma).
    let mut out = BTreeMap::new();
    let Some(comma) = line.find(',') else { return out; };
    for part in split_top_level_commas(&line[comma + 1..]) {
        if let Some((k, v)) = split_kwarg(part.trim()) {
            out.insert(k, v);
        }
    }
    out
