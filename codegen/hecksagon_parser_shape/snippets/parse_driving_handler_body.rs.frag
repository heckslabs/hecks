// Snippet: parse_driving_handler body. Sprint 14 — parses one
// `driving on <kind> "<arg>" do |signal| ... end` block. Captures the
// trigger kind (first whitespace-delimited token : `cron`, `http_post`,
// `file_watch`), the quoted argument (cron expression / URL path /
// filesystem path), then walks inner `dispatch ...` lines via the
// same join_dispatch_lines + parse_driven_dispatch pair used by the
// driven-handler form (the dispatch line shape is identical).
    let first = lines[0].trim();
    let after = match first.strip_prefix("driving on") {
        Some(s) => s.trim(),
        None => return (None, 1),
    };
    let kind_end = after.find(|c: char| c.is_whitespace() || c == '"').unwrap_or(after.len());
    let kind = after[..kind_end].trim().to_string();
    if kind.is_empty() { return (None, 1); }
    let arg = between_quotes(after).unwrap_or_default();
    let mut handler = DrivingHandler { kind, arg, dispatches: Vec::new() };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" { return (Some(handler), i + 1); }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        if t.starts_with("dispatch ") || t.starts_with("dispatch(") {
            let (joined, consumed) = join_dispatch_lines(&lines[i..]);
            if let Some(d) = parse_driven_dispatch(&joined) {
                handler.dispatches.push(d);
            }
            i += consumed;
            continue;
        }
        i += 1;
    }
    (Some(handler), i)
