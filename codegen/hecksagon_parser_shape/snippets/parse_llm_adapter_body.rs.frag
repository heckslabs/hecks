// Snippet: parse_llm_adapter body. Maps the named-adapter form
// `adapter :llm, name: :foo, prompt_template: "...", ...` into an
// LlmAdapter. Returns None when `name:` is absent so absorb_adapter
// can fall back to io_adapter routing for the bare
// `adapter :llm, backend: :claude` form already in production
// (wake_review / musing_mint hecksagons).
    let mut la = LlmAdapter::default();
    let mut got_name = false;
    for (k, v) in parse_options(rest) {
        match k.as_str() {
            "name" => { la.name = strip_symbol(&v); got_name = true; }
            // prompt_template is a Ruby double-quoted string literal —
            // unescape \n / \t / \\ / \" so canonical_ir emits a value
            // identical to the Ruby parser's. strip_quotes alone left
            // them literal and broke parity (i75 musing_mint heal,
            // 2026-05-02).
            "prompt_template" => la.prompt_template = strip_quotes_unescape(&v),
            "model" => la.model = Some(strip_quotes(&v)),
            "max_tokens" => la.max_tokens = v.trim().parse::<u64>().ok(),
            "response_into" => la.response_into_target = Some(strip_quotes(&v)),
            "attr" => la.response_into_attr = Some(strip_symbol(&v)),
            "backend" => la.backend = Some(strip_symbol(&v)),
            _ => {}
        }
    }
    if !got_name { return None; }
    Some(la)
