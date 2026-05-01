// Snippet: parse_gate body. Multi-line block with its own nested
// `end` counter (depth). Emitted verbatim — the outer LineDispatch
// handler_kind = multiline_block delegates here.
//
// Multi-line allow continuation : when an `allow :A, :B,` line ends
// with a comma, subsequent lines until `end` (or a fresh `allow `)
// are treated as continuation of the symbol list. Matches Ruby's
// natural `allow :A, :B, \n :C, :D` shape (closes a parity drift).
    let first = lines[0].trim();
    let mut gate = Gate::default();
    if let Some(n) = between_quotes(first) { gate.aggregate = n; }
    if let Some(after) = first.split(',').nth(1) {
        gate.role = strip_symbol(after.trim().trim_end_matches(" do"));
    }
    let mut i = 1;
    let mut depth = if first.trim_end().ends_with("do") { 1 } else { 0 };
    let mut in_allow = false;
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" { depth -= 1; in_allow = false; i += 1; continue; }
        let body = if let Some(rest) = t.strip_prefix("allow ") {
            Some(rest)
        } else if in_allow {
            Some(t)
        } else {
            None
        };
        if let Some(body_str) = body {
            for sym in body_str.split(',') {
                let name = strip_symbol(sym.trim());
                if !name.is_empty() { gate.allowed_commands.push(name); }
            }
            in_allow = body_str.trim_end().ends_with(',');
        }
        i += 1;
    }
    if gate.aggregate.is_empty() { (None, i) } else { (Some(gate), i) }
