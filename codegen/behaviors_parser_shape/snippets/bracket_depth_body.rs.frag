// Snippet: bracket_depth body. Per-character automaton tracking net
// unclosed bracket depth across `s`, ignoring contents of double-
// quoted strings (with backslash escapes). Used by parse_test to
// decide whether to keep joining continuation lines for a multi-line
// literal (i497).
    let mut depth = 0i32;
    let mut in_str = false;
    let mut prev = '\0';
    for c in s.chars() {
        match c {
            '"' if prev != '\\' => in_str = !in_str,
            '[' | '{' | '(' if !in_str => depth += 1,
            ']' | '}' | ')' if !in_str => depth -= 1,
            _ => {}
        }
        prev = c;
    }
    depth
