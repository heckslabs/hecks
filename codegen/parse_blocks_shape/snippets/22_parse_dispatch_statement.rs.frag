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
/// malformed (no `from:` literal, malformed dotted path, empty parts).
///
/// Two qualified forms accepted :
///   "Aggregate.query_name"            — 2-part (back-compat)
///   "Context.Aggregate.query_name"    — 3-part, disambiguates when
///                                       multiple bluebooks declare
///                                       the same aggregate name (i142
///                                       Context.Aggregate.Command
///                                       resolution applied to query
///                                       lookups too)
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
    let parts: Vec<&str> = literal.split('.').collect();
    let (mut source_context, mut source_aggregate, query_name) = match parts.as_slice() {
        [agg, qry] if !agg.is_empty() && !qry.is_empty() => {
            (None, agg.to_string(), qry.to_string())
        }
        [ctx, agg, qry] if !ctx.is_empty() && !agg.is_empty() && !qry.is_empty() => {
            (Some(ctx.to_string()), agg.to_string(), qry.to_string())
        }
        _ => return None,
    };
    // i221-C — accept the dispatch-FQN `Context::Aggregate.query` form
    // (double-colon context) in the aggregate slot, splitting it so the
    // sweep targets the (context, name) repo key like every other lookup.
    if let Some((ctx, agg)) = source_aggregate.clone().split_once("::") {
        source_context = Some(ctx.to_string());
        source_aggregate = agg.to_string();
    }
    // i221-C — optional `where: { input: from_event(:x) }` sub-hash binds
    // the swept query's inputs from the event. Absent = parameterless.
    let query_inputs = match body.find("where:") {
        Some(wp) => {
            let after_w = &body[wp + "where:".len()..];
            match after_w.find('{') {
                Some(o) => {
                    let c = match_close_brace(&after_w[o..])? + o;
                    parse_with_hash(after_w[o + 1..c].trim())
                }
                None => Vec::new(),
            }
        }
        None => Vec::new(),
    };
    Some(ForEachSpec { source_context, source_aggregate, query_name, query_inputs })
}

