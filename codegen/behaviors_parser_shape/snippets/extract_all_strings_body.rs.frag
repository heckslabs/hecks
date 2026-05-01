// Snippet: extract_all_strings body. Variadic string extractor used
// by the `loads` and `then_events_include` dispatches. Honors
// backslash-escaped quotes inside strings.
    let mut out = Vec::new();
    let bytes = line.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'"' {
            let mut j = i + 1;
            let mut buf = String::new();
            while j < bytes.len() && bytes[j] != b'"' {
                if bytes[j] == b'\\' && j + 1 < bytes.len() {
                    buf.push(bytes[j + 1] as char);
                    j += 2;
                } else {
                    buf.push(bytes[j] as char);
                    j += 1;
                }
            }
            if j < bytes.len() {
                out.push(buf);
                i = j + 1;
                continue;
            } else {
                break;
            }
        }
        i += 1;
    }
    out
