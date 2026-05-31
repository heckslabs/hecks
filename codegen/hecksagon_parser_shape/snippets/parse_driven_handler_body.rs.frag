// Snippet: parse_driven_handler body. Sprint 14 first-adapter slice —
// parses one `driven on "Event" do |e| ... end` block. Captures the
// quoted event_ref then walks inner `dispatch ...` lines through
// join_dispatch_lines + parse_driven_dispatch.
    let first = lines[0].trim();
    let event_ref = match between_quotes(first) { Some(e) => e, None => return (None, 1) };
    let mut handler = DrivenHandler { event_ref, dispatches: Vec::new() };
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
