// [antibody-exempt: parser-shape contract snippet feeding the generated hecksagon parser]
// Snippet: parse_driven_handler body. Sprint 14 first-adapter slice —
// parses one `driven on "Event" do |e| ... end` block. Captures the
// quoted event_ref, an optional `canned do ... end` wrapped-call return
// (memory-canned-defaults-v2 ; values stand in when no `.world` adapter
// entry binds this adapter), then walks inner `dispatch ...` lines
// through join_dispatch_lines + parse_driven_dispatch.
    let first = lines[0].trim();
    let event_ref = match between_quotes(first) { Some(e) => e, None => return (None, 1) };
    let mut handler = DrivenHandler { event_ref, canned: None, dispatches: Vec::new(), runs: Vec::new() };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" { return (Some(handler), i + 1); }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        // Sprint 14 memory-canned-defaults — `canned do ... end` block
        // declares the wrapped-call return value(s) the resolver hands
        // to the follow-on dispatch when no `.world` adapter entry
        // makes this adapter real. The block body is the same k/v shape
        // a hecksagon extension config uses ; `parse_canned_block`
        // collects (key, raw-token) pairs into CannedResponse.values.
        if t == "canned do" || t.starts_with("canned do ") || t.starts_with("canned do;") {
            let (canned, consumed) = parse_canned_block(&lines[i..]);
            if let Some(c) = canned { handler.canned = Some(c); }
            i += consumed;
            continue;
        }
            if t.starts_with("run ") {
                if let Some(cmd) = between_quotes(t) { handler.runs.push(cmd); }
                i += 1;
                continue;
            }
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
