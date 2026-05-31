// Snippet: parse_driven_adapter body. Sprint 14 first-adapter slice —
// block-form `adapter "Name" do ... end` recogniser. Walks the lines
// captured by the `multiline_block` LineDispatch handler ; delegates
// each `driven on "..." do ... end` block to parse_driven_handler.
// Emitted verbatim because the parsing state machine (name capture,
// nested handler dispatch, end terminator) doesn't compress into
// any existing handler_kind template.
    let first = lines[0].trim();
    let name = match between_quotes(first) { Some(n) => n, None => return (None, 1) };
    let mut adapter = DrivenAdapter { name, handlers: Vec::new() };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" { return (Some(adapter), i + 1); }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        if t.starts_with("driven on") {
            let (handler, consumed) = parse_driven_handler(&lines[i..]);
            if let Some(h) = handler { adapter.handlers.push(h); }
            i += consumed;
            continue;
        }
        i += 1;
    }
    (Some(adapter), i)
