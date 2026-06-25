// Snippet: interpret_test_line body. Inner-dispatch table for the
// five tokens that live inside `test do ... end` blocks: tests,
// setup, input, expect, then_events_include. Emitted verbatim — the
// shape stops at the top-level parse() loop.
    if line.is_empty() || line.starts_with('#') { return; }

    if line.starts_with("tests ") || line.starts_with("tests\t") {
        // `tests "CmdName", on: "Pizza"[, kind: :query]`
        if let Some(cmd) = extract_string(line) { test.tests_command = cmd; }
        if let Some(rest) = line.find(',').map(|p| &line[p + 1..]) {
            for part in split_top_level_commas(rest) {
                let part = part.trim();
                if let Some(rest) = part.strip_prefix("on:") {
                    if let Some(s) = extract_string(rest) { test.on_aggregate = s; }
                } else if let Some(rest) = part.strip_prefix("kind:") {
                    let r = rest.trim();
                    let k = r.strip_prefix(':').unwrap_or(r).trim();
                    test.kind = k.trim_end_matches(',').to_string();
                }
            }
        }
    } else if line.starts_with("setup ") || line.starts_with("setup\t") {
        // `setup "CmdName"[, key: value, ...]`
        let command = extract_string(line).unwrap_or_default();
        let args = parse_kwarg_tail(line);
        test.setups.push(TestSetup { command, args });
    } else if line.starts_with("input ") || line.starts_with("input\t") || line == "input" {
        // `input key: value, ...` — kwargs only, no positional
        test.input = parse_kwargs_only(line, "input");
    } else if line.starts_with("expect ") || line.starts_with("expect\t") || line == "expect" {
        test.expect = parse_kwargs_only(line, "expect");
    } else if line.starts_with("then_events_include ")
        || line.starts_with("then_events_include\t")
        || line == "then_events_include"
    {
        // `then_events_include "A", "B", "C"` — set-membership assertion
        // over events fired during the act phase. Variadic, zero or more.
        for name in extract_all_strings(line) {
            test.events_include.push(name);
        }
    }
