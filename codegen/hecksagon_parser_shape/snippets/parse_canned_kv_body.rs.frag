// Snippet: parse_canned_kv body. Sprint 14 memory-canned-defaults —
// parse one `key value` line from inside a `canned do ... end` block.
// Keeps the raw value-token (quoted strings retain their quotes, ints
// stay as digit strings) so the resolver's build_attr_map applies the
// SAME conversion rule the dispatch attrs already use. Sibling of
// world::parser::parse_kv_line ; lives here so the hecksagon parser
// stays self-contained.
    let t = line.trim().trim_end_matches(';');
    let ident_end = t.find(|c: char| !c.is_alphanumeric() && c != '_')?;
    if ident_end == 0 { return None; }
    let key = t[..ident_end].to_string();
    let rest = t[ident_end..].trim().trim_end_matches(';').trim();
    if rest.is_empty() { return None; }
    Some((key, rest.to_string()))
