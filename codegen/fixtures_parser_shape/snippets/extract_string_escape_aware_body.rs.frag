    let bytes = s.as_bytes();
    let start = s.find('"')? + 1;
    let mut i = start;
    while i < bytes.len() {
        let c = bytes[i];
        if c == b'\\' && i + 1 < bytes.len() {
            i += 2;
            continue;
        }
        if c == b'"' {
            return Some(s[start..i].to_string());
        }
        i += 1;
    }
    None
