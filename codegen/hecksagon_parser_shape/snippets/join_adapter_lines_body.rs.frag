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
            let raw_t = lines[idx];
            consumed += 1;
            idx += 1;
            // Strip trailing `# ...` comment outside string literals,
            // then trim. Without this, a line like
            //     endpoint   "https://api.example.com"   # prod host
            // emitted `endpoint: "https://api.example.com" # ...` and
            // strip_quotes (matches both ends) left the literal quotes
            // intact, which broke downstream URL construction in any
            // adapter consumer that expected a
            // clean value. Inlined here (not pulled into its own helper)
            // so the specializer golden (codegen/hecksagon_parser_shape/
            // snippets/join_adapter_lines_body.rs.frag) stays a single
            // self-contained snippet — no new ParserHelper fixture row
            // needed.
            let cleaned: String = {
                let mut out = String::with_capacity(raw_t.len());
                let mut in_str = false;
                let mut prev = '\0';
                for c in raw_t.chars() {
                    match c {
                        '"' if prev != '\\' => { in_str = !in_str; out.push(c); }
                        '#' if !in_str => break,
                        _ => out.push(c),
                    }
                    prev = c;
                }
                out
            };
            let t = cleaned.trim();
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
