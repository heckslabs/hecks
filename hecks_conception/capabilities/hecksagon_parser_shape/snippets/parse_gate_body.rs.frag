// Snippet: parse_gate body. Multi-line block with its own nested
// `end` counter (depth). Emitted verbatim — the outer LineDispatch
// handler_kind = multiline_block delegates here.
    let first = lines[0].trim();
    let mut gate = Gate::default();
    if let Some(n) = between_quotes(first) { gate.aggregate = n; }
    if let Some(after) = first.split(',').nth(1) {
        gate.role = strip_symbol(after.trim().trim_end_matches(" do"));
    }
    let mut i = 1;
    let mut depth = if first.trim_end().ends_with("do") { 1 } else { 0 };
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" { depth -= 1; i += 1; continue; }
        if let Some(rest) = t.strip_prefix("allow ") {
            for sym in rest.split(',') {
                let name = strip_symbol(sym.trim());
                if !name.is_empty() { gate.allowed_commands.push(name); }
            }
        }
        i += 1;
    }
    if gate.aggregate.is_empty() { (None, i) } else { (Some(gate), i) }
