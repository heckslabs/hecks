/// Parse one `on "Event", transition: { from: :to } do |event, pm|` line
/// into a ProcessManagerHandler. Returns None if the shape is unparseable.
///
/// Source forms recognized :
///   on "Event", transition: { light: :light } do |event, pm|
///   on "Event", transition: { :light => :rem } do |event, pm|
fn parse_pm_handler(line: &str) -> Option<ProcessManagerHandler> {
    let event_type = extract_string(line)?;
    // Pull the `{ … }` after `transition:`. The action's `do |event, pm|`
    // tail comes AFTER the transition hash, so we look for the first
    // `{` and its matching `}` to bound the hash.
    let trans_pos = line.find("transition:")?;
    let after = &line[trans_pos + "transition:".len()..];
    let open = after.find('{')?;
    let close = after[open..].find('}')? + open;
    let body = after[open + 1..close].trim();
    // Body is one of :
    //   `from: :to`        — symbol-rocket sugar
    //   `:from => :to`     — explicit hash-rocket
    let (from, to) = if body.contains("=>") {
        let mut parts = body.splitn(2, "=>");
        let lhs = parts.next()?.trim();
        let rhs = parts.next()?.trim();
        let from = lhs.trim_start_matches(':').trim_end_matches(',').trim().to_string();
        let to = rhs.trim_start_matches(':').trim().to_string();
        (from, to)
    } else {
        let colon = body.find(':')?;
        let from = body[..colon].trim().to_string();
        let rhs = body[colon + 1..].trim().trim_start_matches(':').trim();
        let to = rhs.split(|c: char| c == ',' || c.is_whitespace())
            .next().unwrap_or("").to_string();
        (from, to)
    };
    if from.is_empty() || to.is_empty() { return None; }
    Some(ProcessManagerHandler {
        event_type,
        from_state: from,
        to_state: to,
        dispatches: vec![],
        set_specs: vec![],
    })
}

