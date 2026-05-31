// Snippet: parse_driven_dispatch body. Sprint 14 first-adapter slice —
// parses a joined `dispatch "FQN", k1: v1, k2: v2` line into a
// DrivenDispatch. First quoted token is the command FQN ; the
// remaining attrs are parsed via parse_options.
    let body = joined.trim()
        .strip_prefix("dispatch")
        .map(|s| s.trim_start_matches('(').trim())
        .unwrap_or(joined);
    let command = between_quotes(body)?;
    // After the first quoted token (`"FQN"`), the attrs start at the
    // following comma. Find that comma at top level and parse the tail
    // as `parse_options` does.
    let mut depth = 0i32;
    let mut in_str = false;
    let mut prev = '\0';
    let mut split_at: Option<usize> = None;
    for (idx, c) in body.char_indices() {
        match c {
            '"' if prev != '\\' => in_str = !in_str,
            '(' | '[' | '{' if !in_str => depth += 1,
            ')' | ']' | '}' if !in_str => depth -= 1,
            ',' if !in_str && depth == 0 => { split_at = Some(idx); break; }
            _ => {}
        }
        prev = c;
    }
    let attrs = match split_at {
        Some(idx) => parse_options(body[idx + 1..].trim_end_matches(')').trim()),
        None => Vec::new(),
    };
    Some(DrivenDispatch { command, attrs })
