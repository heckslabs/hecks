// Snippet: parse_tts_adapter body. Maps the named-adapter form
// `adapter :tts, name: :foo, provider: :elevenlabs, voice_id: "...",
// model:, speed:, stability:, similarity_boost:, style:,
// trigger_on:, cache_dir:, auto_play:` into a TtsAdapter. Returns
// None when `name:` is absent — the caller falls back to io_adapter
// routing for any bare `:tts` form (forwards-compat, mirrors
// parse_llm_adapter / parse_compute_adapter's contract). `:tts` is
// fire-and-forget (`response_field :none`) so there is no
// response_into / attr pair.
    let mut ta = TtsAdapter::default();
    let mut got_name = false;
    for (k, v) in parse_options(rest) {
        match k.as_str() {
            "name" => { ta.name = strip_symbol(&v); got_name = true; }
            "provider" => ta.provider = Some(strip_symbol(&v)),
            "voice_id" => ta.voice_id = Some(strip_quotes(&v)),
            "model" => ta.model = Some(strip_quotes(&v)),
            "speed" => ta.speed = Some(strip_quotes(&v)),
            "stability" => ta.stability = Some(strip_quotes(&v)),
            "similarity_boost" => ta.similarity_boost = Some(strip_quotes(&v)),
            "style" => ta.style = Some(strip_quotes(&v)),
            "trigger_on" => ta.trigger_on = Some(strip_quotes(&v)),
            "cache_dir" => ta.cache_dir = Some(strip_quotes(&v)),
            "auto_play" => ta.auto_play = Some(strip_quotes(&v)),
            _ => {}
        }
    }
    if !got_name { return None; }
    Some(ta)
