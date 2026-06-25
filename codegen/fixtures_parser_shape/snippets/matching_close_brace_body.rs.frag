    let bytes = s.as_bytes();
    if bytes.get(open) != Some(&b'{') { return None; }
    let mut depth = 0i32;
    let mut in_str = false;
    let mut i = open;
    while i < bytes.len() {
        let c = bytes[i] as char;
        match c {
            '"' if !escaped_at(s, i) => in_str = !in_str,
            '{' if !in_str => depth += 1,
            '}' if !in_str => {
                depth -= 1;
                if depth == 0 { return Some(i); }
            }
            _ => {}
        }
        i += 1;
    }
    None
