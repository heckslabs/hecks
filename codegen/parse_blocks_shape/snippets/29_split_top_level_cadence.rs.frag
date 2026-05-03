/// Split a kwarg list on top-level commas only — bracket / brace /
/// paren / string contents are protected. Cadence-local helper.
fn split_top_level_cadence(s: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut buf = String::new();
    let mut depth: i32 = 0;
    let mut in_str = false;
    let mut prev = '\0';
    for c in s.chars() {
        match c {
            '"' if prev != '\\' => { in_str = !in_str; buf.push(c); }
            '[' | '{' | '(' if !in_str => { depth += 1; buf.push(c); }
            ']' | '}' | ')' if !in_str => { depth -= 1; buf.push(c); }
            ',' if !in_str && depth == 0 => {
                out.push(buf.trim().to_string());
                buf.clear();
            }
            _ => buf.push(c),
        }
        prev = c;
    }
    if !buf.trim().is_empty() { out.push(buf.trim().to_string()); }
    out
}
