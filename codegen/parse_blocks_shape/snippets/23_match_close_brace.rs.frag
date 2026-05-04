/// Given a slice that starts at `{`, return the index of the matching
/// `}` (counting depth). Returns None when unmatched. Quotes are not
/// respected — same approximation as `is_balanced`.
fn match_close_brace(s: &str) -> Option<usize> {
    let mut depth = 0i32;
    for (i, c) in s.char_indices() {
        match c {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 { return Some(i); }
            }
            _ => (),
        }
    }
    None
}

