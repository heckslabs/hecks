// Snippet: parse_canned_block body. Sprint 14 memory-canned-defaults —
// parse one `canned do ... end` block declared inside a `driven on`
// handler. Each inner line is a `key value` pair (e.g. `output "ack"`,
// `exit_code 0`) captured verbatim into CannedResponse.values ; the
// resolver translates per-attr at fire time using build_attr_map.
//
// Supports both inline (`canned do; k v; k v end`) and block
// (`canned do\n  k v\n  k v\nend`) shapes ; mirrors the symmetric
// inline-vs-block handling in world's parse_extension_block.
    let first = lines[0].trim();
    let mut canned = CannedResponse { values: Vec::new() };

    // Inline form : `canned do; output "ack"; exit_code 0 end`
    if first.ends_with("end") && first.contains("do") {
        let body = first
            .trim_start_matches("canned")
            .trim()
            .trim_start_matches("do")
            .trim_start_matches(|c: char| c == ';' || c.is_whitespace())
            .trim_end()
            .trim_end_matches("end")
            .trim();
        for piece in body.split(';') {
            let p = piece.trim();
            if p.is_empty() { continue; }
            if let Some(kv) = parse_canned_kv(p) { canned.values.push(kv); }
        }
        return (Some(canned), 1);
    }

    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" { return (Some(canned), i + 1); }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        if let Some(kv) = parse_canned_kv(t) { canned.values.push(kv); }
        i += 1;
    }
    (Some(canned), i)
