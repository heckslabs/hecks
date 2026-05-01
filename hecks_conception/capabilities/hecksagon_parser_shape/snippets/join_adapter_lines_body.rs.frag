// Snippet: join_adapter_lines body. Per-character string-state
// automaton — tracks in_str, prev char, and paren/bracket/brace
// depth. Emitted verbatim; not templatable.
//
// Block-form `adapter :shell, name: :x do ... end` is flattened
// into kwargs : each indented `key value` line inside the block
// becomes `, key: value` appended to the joined string. Closes the
// shell_demo.hecksagon parity drift.
    let mut joined = String::new();
    let mut consumed = 0;
    let mut depth: i32 = 0;
    let mut in_str = false;
    let mut idx = 0;
    while idx < lines.len() {
        let t = lines[idx].trim();
        consumed += 1;
        idx += 1;
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
    if joined.trim_end().ends_with(" do") {
        joined = joined.trim_end().trim_end_matches(" do").trim_end().to_string();
        while idx < lines.len() {
            let t = lines[idx].trim();
            consumed += 1;
            idx += 1;
            if t.is_empty() || t.starts_with('#') { continue; }
            if t == "end" { break; }
            if let Some(sp) = t.find(char::is_whitespace) {
                let key = &t[..sp];
                let val = t[sp..].trim();
                joined.push_str(", ");
                joined.push_str(key);
                joined.push_str(": ");
                joined.push_str(val);
            }
        }
    }
    (joined, consumed)
