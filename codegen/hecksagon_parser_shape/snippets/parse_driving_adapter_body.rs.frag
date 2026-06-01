// Snippet: parse_driving_adapter body. Sprint 14 — sibling of
// parse_driven_adapter for externally-triggered adapters
// (`driving on cron / http_post / file_watch`). Same block shape
// (`adapter "Name" do ... end`), different inner handler kind.
// Walks the same lines parse_driven_adapter does ; routes `driving
// on` blocks to parse_driving_handler while skipping past `driven on`
// blocks (already captured by parse_driven_adapter on the first pass).
    let first = lines[0].trim();
    let name = match between_quotes(first) { Some(n) => n, None => return (None, 1) };
    let mut adapter = DrivingAdapter { name, handlers: Vec::new() };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" { return (Some(adapter), i + 1); }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        if t.starts_with("driving on") {
            let (handler, consumed) = parse_driving_handler(&lines[i..]);
            if let Some(h) = handler { adapter.handlers.push(h); }
            i += consumed;
            continue;
        }
        // Driven blocks already consumed by parse_driven_adapter on the
        // first pass ; skip past them here without double-handling.
        if t.starts_with("driven on") {
            let (_, consumed) = parse_driven_handler(&lines[i..]);
            i += consumed;
            continue;
        }
        i += 1;
    }
    (Some(adapter), i)
