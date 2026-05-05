// Snippet: parse_test body. Depth-tracking multiline-block parser
// invoked by the `test` LineDispatch (handler_kind =
// multiline_block_direct). Nested `end`s handled via a simple
// counter; inner lines dispatched through interpret_test_line.
//
// i258 — line continuations. Ruby's `input k: v, k2: v2` form may
// span multiple lines when the kwargs list is long ; `input k: v,\n
// k2: v2` is one logical call. The Rust parser is line-based, so we
// pre-join continuation lines (a line ending with `,` carries onto
// the next) before dispatching to interpret_test_line. Without this,
// only the first physical line's kwargs reach the IR — every other
// kwarg silently drops, downstream the runtime falls back to the VO
// `apply_defaults` path (Value::List(vec![])) and renders as
// `[0 items]`. Bin-buddy's Subscribe/AddAddress/SetInventory/
// RegisterPlan tests broke on this.
    let first = lines[0].trim();
    let description = extract_string(first).unwrap_or_default();
    let mut test = Test {
        description,
        tests_command: String::new(),
        on_aggregate: String::new(),
        kind: "command".to_string(),
        setups: vec![],
        input: BTreeMap::new(),
        expect: BTreeMap::new(),
        events_include: vec![],
    };

    let mut i = 1;
    let mut depth = 1usize;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();
        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
        } else if ends_with_do_block(line) {
            depth += 1;
        } else if depth == 1 {
            // Join continuation lines : keep absorbing the next line
            // while the current ends with `,` (Ruby's natural multi-
            // line kwargs form). String literals and bracket depth
            // are honored by the kwargs splitter downstream ; here we
            // only care that the joined logical line carries every
            // kwarg into interpret_test_line.
            let mut joined = line.to_string();
            while joined.trim_end().ends_with(',') && i + 1 < lines.len() {
                let peek = lines[i + 1].trim();
                if peek == "end" || peek.is_empty() || peek.starts_with('#') {
                    break;
                }
                joined.push(' ');
                joined.push_str(peek);
                i += 1;
            }
            interpret_test_line(&joined, &mut test);
        }
        i += 1;
    }
    (test, i + 1)
