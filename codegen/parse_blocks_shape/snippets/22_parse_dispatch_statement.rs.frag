/// Parse one (possibly glued-multi-line) `dispatch "Cmd"` statement
/// into a structured DispatchSpec. Two source forms recognized :
///
///   dispatch "Aggregate.Command"
///   dispatch "Aggregate.Command", with: { foo: from_event(:bar),
///                                         baz: "lit",
///                                         qux: from_pm(:n, default: "—") }
///
/// Returns None when the shape is unparseable. The caller's outer
/// walk skips non-dispatch lines via `is_dispatch_start`, so this
/// function is called only on confirmed dispatch statements.
fn parse_dispatch_statement(line: &str) -> Option<DispatchSpec> {
    let trimmed = line.trim();
    if !is_dispatch_start(trimmed) { return None; }
    let command_name = extract_string(trimmed)?;

    // Find the `with:` keyword. Tolerant of variable whitespace
    // around the comma (e.g. `dispatch "X",   with: {...}`). The
    // search starts after the closing quote of the command name so
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

    Some(DispatchSpec {
        command_name,
        with_spec,
    })
}

