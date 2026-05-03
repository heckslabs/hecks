/// Returns true when every `(`/`)` and `{`/`}` pair in `s` is matched.
/// Used to detect the end of a multi-line `dispatch ..., with: { ... }`
/// statement. Quotes are not respected — a `{` or `(` inside a string
/// would mis-balance. The DSL surface today doesn't put braces in
/// string literals, so this approximation holds ; sources that do
/// would be surfaced as parser drift in parity tests.
fn is_balanced(s: &str) -> bool {
    let mut paren = 0i32;
    let mut brace = 0i32;
    for c in s.chars() {
        match c {
            '(' => paren += 1,
            ')' => paren -= 1,
            '{' => brace += 1,
            '}' => brace -= 1,
            _ => (),
        }
    }
    paren == 0 && brace == 0
}

