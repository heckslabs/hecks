// Snippet: join_adapter_lines body. Per-character string-state
// automaton — tracks in_str, prev char, and paren/bracket/brace
// depth. Emitted verbatim; not templatable.
    let mut joined = String::new();
    let mut consumed = 0;
    let mut depth: i32 = 0;
    let mut in_str = false;
    for line in lines {
        let t = line.trim();
        consumed += 1;
        if t.is_empty() || t.starts_with('#') {
            if !joined.is_empty() && depth > 0 { continue; }
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
