// Snippet: split_top_level_commas body. Per-character string-state
// automaton — commas outside strings/brackets/parens/braces only.
    let mut parts = Vec::new();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut prev = '\0';
    let mut start = 0usize;
    for (i, c) in s.char_indices() {
        match c {
            '"' if prev != '\\' => in_str = !in_str,
            '[' | '{' | '(' if !in_str => depth += 1,
            ']' | '}' | ')' if !in_str => depth -= 1,
            ',' if !in_str && depth == 0 => {
                parts.push(&s[start..i]);
                start = i + 1;
            }
            _ => {}
        }
        prev = c;
    }
    if start < s.len() { parts.push(&s[start..]); }
    parts
