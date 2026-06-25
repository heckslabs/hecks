// True if the line is incomplete and the next physical line is a
// continuation: either trailing comma, or unbalanced brackets/parens/braces
// (outside string literals).
#[allow(dead_code)]
fn needs_continuation(s: &str) -> bool {
    let trimmed = s.trim_end();
    if trimmed.ends_with(',') { return true; }
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
    depth > 0
}
