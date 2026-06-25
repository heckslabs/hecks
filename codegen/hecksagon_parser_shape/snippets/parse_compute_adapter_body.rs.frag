// Snippet: parse_compute_adapter body. Maps the named-adapter form
// `adapter :compute, name: :foo, function: "fn_name", trigger_on:,
// response_into:, attr:` into a ComputeAdapter. Returns None when
// `name:` is absent — the caller falls back to io_adapter routing
// for any bare `:compute` form (forwards-compat, mirrors
// parse_llm_adapter's contract).
//
// i220 sub-gap 5 (compute-adapter-primitive) — sibling of
// parse_llm_adapter. Where `:llm` substitutes a prompt and chains
// through a backend provider, `:compute` resolves a function name
// against the static compute_functions registry and chains the
// returned string into the response target.
    let mut ca = ComputeAdapter::default();
    let mut got_name = false;
    for (k, v) in parse_options(rest) {
        match k.as_str() {
            "name" => { ca.name = strip_symbol(&v); got_name = true; }
            // `function:` is a string identifier (the registry key).
            // Accept symbol form `:summarize_recent_musings` AND
            // string form `"summarize_recent_musings"` — both
            // canonicalize to the bare identifier.
            "function" => {
                let stripped = strip_quotes(&v);
                ca.function_name = if stripped == v { strip_symbol(&v) } else { stripped };
            }
            "trigger_on" => ca.trigger_on = Some(strip_quotes(&v)),
            "response_into" => ca.response_into_target = Some(strip_quotes(&v)),
            "attr" => ca.response_into_attr = Some(strip_symbol(&v)),
            _ => {}
        }
    }
    if !got_name { return None; }
    Some(ca)
