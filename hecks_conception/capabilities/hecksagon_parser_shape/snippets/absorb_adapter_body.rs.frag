// Snippet: absorb_adapter body. Sorts a joined `adapter …` line into
// persistence / io / shell buckets. Emitted verbatim because the
// match on `kind.as_str()` fans out to three distinct shapes and
// doesn't fit a handler_kind primitive.
    let body = joined.trim()
        .strip_prefix("adapter")
        .map(|s| s.trim_start_matches('(').trim())
        .unwrap_or(joined);
    let (kind, rest) = split_first_symbol(body);
    if kind.is_empty() { return; }
    match kind.as_str() {
        "shell" => {
            if let Some(sa) = parse_shell_adapter(rest) { hex.shell_adapters.push(sa); }
        }
        "memory" | "heki" => { hex.persistence = Some(kind); }
        _ => {
            let mut io = IoAdapter { kind, options: parse_options(rest), on_events: vec![] };
            for ev in extract_on_events(rest) { io.on_events.push(ev); }
            hex.io_adapters.push(io);
        }
    }
