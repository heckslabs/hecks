/// Parse one (possibly glued-multi-line) `dispatch "Cmd"` statement
/// into a structured DispatchSpec. Three source forms recognized :
///
///   dispatch "Aggregate.Command"
///   dispatch "Aggregate.Command", with: { foo: from_event(:bar),
///                                         baz: "lit",
///                                         qux: from_pm(:n, default: "—") }
///   dispatch "Aggregate.Command",
///     for_each: { from: "Aggregate.query_name" },
///     with: { id: from_iter(:id) }
///
/// Returns None when the shape is unparseable. The caller's outer
/// walk skips non-dispatch lines via `is_dispatch_start`, so this
/// function is called only on confirmed dispatch statements.
fn parse_dispatch_statement(line: &str) -> Option<DispatchSpec> {
    let trimmed = line.trim();
    if !is_dispatch_start(trimmed) { return None; }
    let command_name = extract_string(trimmed)?;

    // Find the `with:` and `for_each:` keywords. Tolerant of variable
    // whitespace around the comma (e.g. `dispatch "X",   with: {...}`).
    // The search starts after the closing quote of the command name so
    // a stray `with:` inside the command string can't false-match.
    let cmd_end = match trimmed.match_indices('"').nth(1) {
        Some((idx, _)) => idx + 1,
        None => trimmed.len(),
    };
    let tail = &trimmed[cmd_end..];

    let with_spec = match tail.find("with:") {
        None => Vec::new(),
        Some(pos) => {
            let after = &tail[pos + "with:".len()..];
            let open = after.find('{')?;
            // The matching close brace bounds the with hash. Use a
            // depth counter so nested `from_event(:foo)` parens or any
            // future nested hash don't trip the search.
            let close = match_close_brace(&after[open..])? + open;
            let body = after[open + 1..close].trim();
            parse_with_hash(body)
        }
    };

    // i221-A — sweep dispatch. `for_each: { from: "Aggregate.query" }`
    // splits on the first dot into the two structured halves. Absent
    // `for_each:` leaves `for_each = None` (the back-compat default).
    let for_each = parse_for_each_clause(tail);

    Some(DispatchSpec {
        command_name,
        with_spec,
        for_each,
    })
}

/// i221-A — locate the `for_each: { from: "Aggregate.query_name" }`
/// clause in a dispatch line and lift it to a `ForEachSpec`. Returns
/// `None` when the clause is absent (the common back-compat case) or
/// malformed (no `from:` literal, no qualifying dot, empty halves).
fn parse_for_each_clause(tail: &str) -> Option<ForEachSpec> {
    let pos = tail.find("for_each:")?;
    let after = &tail[pos + "for_each:".len()..];
    let open = after.find('{')?;
    let close = match_close_brace(&after[open..])? + open;
    let body = after[open + 1..close].trim();
    // Body shape : `from: "Aggregate.query_name"` (kwarg-shorthand).
    // Hash-rocket form (`:from => "..."`) is not used in the corpus
    // and would be filed as a follow-on.
    let from_pos = body.find("from:")?;
    let value_raw = body[from_pos + "from:".len()..].trim();
    let literal = extract_string(value_raw)?;
    let dot = literal.find('.')?;
    if dot == 0 || dot == literal.len() - 1 {
        return None;
    }
    let source_aggregate = literal[..dot].to_string();
    let query_name = literal[dot + 1..].to_string();
    Some(ForEachSpec { source_aggregate, query_name })
}

