// Snippet: join_dispatch_lines body. Sprint 14 first-adapter slice —
// mirrors join_adapter_lines but stops at the natural end of one
// `dispatch ...` call (single expression ; no do/end block). Joins
// continuation lines until parens/brackets balance AND the latest
// non-comment line doesn't end with a comma.
    let mut joined = String::new();
    let mut consumed = 0;
    let mut depth: i32 = 0;
    let mut in_str = false;
    for raw in lines.iter() {
        let t = raw.trim();
        consumed += 1;
        if t.is_empty() || t.starts_with('#') {
            if joined.is_empty() { continue; }
            continue;
        }
        if !joined.is_empty() { joined.push(' '); }
        joined.push_str(t);
        let mut prev = '\0';
        for c in t.chars() {
            match c {
                '"' if prev != '\\' => in_str = !in_str,
                '(' | '[' | '{' if !in_str => depth += 1,
                ')' | ']' | '}' if !in_str => depth -= 1,
                _ => {}
            }
            prev = c;
        }
        let ends_comma = t.trim_end().ends_with(',');
        if depth <= 0 && !ends_comma { break; }
    }
    (joined, consumed)
