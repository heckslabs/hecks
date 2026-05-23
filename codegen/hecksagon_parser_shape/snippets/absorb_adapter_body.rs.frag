// Snippet: absorb_adapter body. Sorts a joined `adapter …` line into
// persistence / io / shell / llm buckets. Emitted verbatim because the
// match on `kind.as_str()` fans out to four distinct shapes and
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
        "llm" => {
            if let Some(la) = parse_llm_adapter(rest) {
                hex.llm_adapters.push(la);
            } else {
                // Bare `adapter :llm, backend: :claude` form (no name:) —
                // keep backward-compat with existing wake_review /
                // musing_mint hecksagons that route through io_adapter.
                let mut io = IoAdapter { kind, options: parse_options(rest), on_events: vec![] };
                for ev in extract_on_events(rest) { io.on_events.push(ev); }
                hex.io_adapters.push(io);
            }
        }
        // i220 sub-gap 5 — sibling of `:llm`. Same shape as
        // parse_llm_adapter / fallback to io_adapter when `name:` is
        // absent, so a bare `adapter :compute, root: "."` (if anyone
        // ever writes one) still lands as an io adapter rather than
        // disappearing.
        "compute" => {
            if let Some(ca) = parse_compute_adapter(rest) {
                hex.compute_adapters.push(ca);
            } else {
                let mut io = IoAdapter { kind, options: parse_options(rest), on_events: vec![] };
                for ev in extract_on_events(rest) { io.on_events.push(ev); }
                hex.io_adapters.push(io);
            }
        }
        // i-tts — sibling of `:llm` / `:compute`. Named form parses
        // into a typed TtsAdapter ; a bare `adapter :tts, provider: :x`
        // (no name:) falls back to io_adapter, same forwards-compat
        // contract as the compute arm above.
        "tts" => {
            if let Some(ta) = parse_tts_adapter(rest) {
                hex.tts_adapters.push(ta);
            } else {
                let mut io = IoAdapter { kind, options: parse_options(rest), on_events: vec![] };
                for ev in extract_on_events(rest) { io.on_events.push(ev); }
                hex.io_adapters.push(io);
            }
        }
        "memory" | "heki" => { hex.persistence = Some(kind); }
        // SQL persistence kinds — `adapter :sqlite, db: "app.db"` (and
        // the postgres/mysql siblings) route into persistence with the
        // kind string AND the connection options (db:/host:/user:/name:).
        // Only the kind crosses the canonical-IR parity boundary ; the
        // options are the runtime's SQL-connect concern. Mirrors Ruby's
        // HecksagonBuilder#adapter, which folds these kinds into
        // `@persistence = { type: k }.merge(opts)`.
        "sqlite" | "postgres" | "mysql" => {
            hex.persistence = Some(kind);
            hex.persistence_options = parse_options(rest);
        }
        _ => {
            let mut io = IoAdapter { kind, options: parse_options(rest), on_events: vec![] };
            for ev in extract_on_events(rest) { io.on_events.push(ev); }
            hex.io_adapters.push(io);
        }
    }
