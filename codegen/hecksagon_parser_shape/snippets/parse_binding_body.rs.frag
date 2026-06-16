// Snippet: parse_binding body. bucket-3 step 2 — decompose one hexagon
// bind `aggregate . verb ( "adapter" [, on: "event"] )` into a Binding.
// The aggregate FQN may itself contain `::`, so the verb split is the
// LAST `.` before the opening paren. The first quoted token is the
// adapter (positional) ; `on: "..."` (optional) is the triggering event
// for an effect port.
//
// An EFFECT port carries a verdict block : the bind line ends with `do`
// and the following lines name `success "..."` / `failure "..."` until
// `end` — the discriminated re-entry commands. A reply / fulfillment bind
// has no block and consumes exactly one line.
//
// SCOPE: reply + effect only. A fulfillment line `Aggregate.on("Event")`
// ALSO matches is_binding_line and would decompose WRONG here — verb
// "on", adapter = the event. Inert today (no such line in the corpus),
// but a later step that adds fulfillment must EXTEND this fn.
        let t = lines[0].trim();
        let paren = match t.find('(') { Some(p) => p, None => return (None, 1) };
        let head = &t[..paren];
        let dot = match head.rfind('.') { Some(d) => d, None => return (None, 1) };
        let aggregate = head[..dot].trim().to_string();
        let verb = head[dot + 1..].trim().to_string();
        if aggregate.is_empty() || verb.is_empty() { return (None, 1); }
        let args = &t[paren + 1..];
        let adapter = between_quotes(args).unwrap_or_default();
        let on = match args.find("on:") {
            Some(idx) => between_quotes(&args[idx..]).unwrap_or_default(),
            None => String::new(),
        };
        // The effect-port verdict block : `do success "..." failure "..." end`.
        // When the bind line ends with `do`, walk the inner lines collecting the
        // success / failure re-entry commands until the matching `end`. Reply /
        // fulfillment binds have no block — success/failure stay empty, one line.
        let mut success = String::new();
        let mut failure = String::new();
        let mut consumed = 1;
        if t.trim_end().ends_with("do") {
            let mut i = 1;
            while i < lines.len() {
                let b = lines[i].trim();
                i += 1;
                if b == "end" { break; }
                if let Some(rest) = b.strip_prefix("success") {
                    if let Some(v) = between_quotes(rest) { success = v; }
                } else if let Some(rest) = b.strip_prefix("failure") {
                    if let Some(v) = between_quotes(rest) { failure = v; }
                }
            }
            consumed = i;
        }
        (Some(Binding { aggregate, verb, adapter, on, success, failure }), consumed)
