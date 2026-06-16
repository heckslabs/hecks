// Snippet: parse_binding body. bucket-3 step 2 — decompose one hexagon
// bind `aggregate . verb ( "adapter" [, on: "event"] )` into a Binding.
// The aggregate FQN may itself contain `::`, so the verb split is the
// LAST `.` before the opening paren. The first quoted token is the
// adapter (positional) ; `on: "..."` (optional) is the triggering event
// for an effect port. Always consumes exactly one line.
//
// SCOPE: reply + effect only. A fulfillment line `Aggregate.on("Event")`
// ALSO matches is_binding_line and would decompose WRONG here — verb
// "on", adapter = the event. Inert today (no such line in the corpus ;
// bindings aren't consulted yet), but a later bucket-3 step that adds
// fulfillment must EXTEND this fn (branch on verb == "on"), not just add
// a dispatch row.
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
    // `into: "Order.Authorize | Order.Decline"` — the effect-port verdict union,
    // success first, failure second. Split on `|`, trim each. `find("into:")`
    // cannot collide with `on:` (the substring `on:` does not occur in `into:`).
    let into: Vec<String> = match args.find("into:") {
        Some(idx) => between_quotes(&args[idx..])
            .unwrap_or_default()
            .split('|')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
        None => Vec::new(),
    };
    (Some(Binding { aggregate, verb, adapter, on, into }), 1)
