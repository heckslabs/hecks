// Snippet: parse_test body. Depth-tracking multiline-block parser
// invoked by the `test` LineDispatch (handler_kind =
// multiline_block_direct). Nested `end`s handled via a simple
// counter; inner lines dispatched through interpret_test_line.
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
            interpret_test_line(line, &mut test);
        }
        i += 1;
    }
    (test, i + 1)
