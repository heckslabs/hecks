//! Behaviors parser — reads `_behavioral_tests.bluebook` files into a TestSuite.
//!
//! Surface (kept small on purpose):
//!
//!   Hecks.behaviors "Pizzas" do
//!     vision "..."
//!     test "description" do
//!       tests "CmdName", on: "Aggregate"          # required
//!       tests "QueryName", on: "Aggregate", kind: :query
//!       setup "CmdName", arg: "value", n: 1       # zero or more
//!       input arg: "value"                        # one
//!       expect attr: "value", count: 2            # one
//!     end
//!   end
//!
//! Mirrors `parser.rs` in style: line-based, `ends_with_do_block` for
//! depth tracking, `extract_string`/`extract_after` for token extraction.

use crate::behaviors_ir::*;
use crate::parser_helpers::*;
use std::collections::BTreeMap;

pub fn parse(source: &str) -> TestSuite {
    let mut suite = TestSuite {
        name: String::new(),
        vision: None,
        tests: vec![],
    };
    let lines: Vec<&str> = source.lines().collect();
    let mut i = 0;

    while i < lines.len() {
        let line = lines[i].trim();

        if line.starts_with("Hecks.behaviors") {
            if let Some(name) = extract_string(line) { suite.name = name; }
        } else if line.starts_with("vision") {
            if let Some(v) = extract_string(line) { suite.vision = Some(v); }
        } else if line.starts_with("test ") || line.starts_with("test\t") {
            let (test, consumed) = parse_test(&lines[i..]);
            suite.tests.push(test);
            i += consumed;
            continue;
        }
        i += 1;
    }

    suite
}

fn parse_test(lines: &[&str]) -> (Test, usize) {
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
}

fn interpret_test_line(line: &str, test: &mut Test) {
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
    }
}

/// Parse the kwargs following a positional first arg (everything after the
/// first comma). For lines like `setup "CreatePizza", name: "x", amount: 5`.
fn parse_kwarg_tail(line: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let Some(comma) = line.find(',') else { return out; };
    for part in split_top_level_commas(&line[comma + 1..]) {
        if let Some((k, v)) = split_kwarg(part.trim()) {
            out.insert(k, v);
        }
    }
    out
}

/// Parse kwargs after a leading keyword (`input` / `expect`).
fn parse_kwargs_only(line: &str, keyword: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let Some(start) = line.find(keyword) else { return out; };
    let body = line[start + keyword.len()..].trim();
    if body.is_empty() { return out; }
    for part in split_top_level_commas(body) {
        if let Some((k, v)) = split_kwarg(part.trim()) {
            out.insert(k, v);
        }
    }
    out
}

/// Split `key: value` into (key, value-as-source-token). Strings are
/// unwrapped; numbers/symbols/bare tokens kept as their source bytes.
fn split_kwarg(part: &str) -> Option<(String, String)> {
    let colon = part.find(':')?;
    let key = part[..colon].trim().to_string();
    if key.is_empty()
        || !key.chars().next().map_or(false, |c| c.is_ascii_lowercase())
        || !key.chars().all(|c| c.is_alphanumeric() || c == '_')
    {
        return None;
    }
    let raw = part[colon + 1..].trim().trim_end_matches(',').trim();
    let val = if raw.starts_with('"') {
        extract_string(raw).unwrap_or_else(|| raw.to_string())
    } else {
        raw.to_string()
    };
    Some((key, val))
}

/// Split `s` on top-level commas (outside strings, brackets, parens, braces).
fn split_top_level_commas(s: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut prev = '\0';
    let mut start = 0usize;
    for (i, c) in s.char_indices() {
        match c {
            '"' if prev != '\\' => in_str = !in_str,
            '[' | '{' | '(' if !in_str => depth += 1,
            ']' | '}' | ')' if !in_str => depth -= 1,
            ',' if !in_str && depth == 0 => {
                parts.push(&s[start..i]);
                start = i + 1;
            }
            _ => {}
        }
        prev = c;
    }
    if start < s.len() { parts.push(&s[start..]); }
    parts
}

/// Returns true if the source's first non-blank, non-comment line is the
/// `Hecks.behaviors` keyword. Used by callers to dispatch to this parser
/// instead of the regular bluebook parser.
pub fn is_behaviors_source(source: &str) -> bool {
    for line in source.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') { continue; }
        return t.starts_with("Hecks.behaviors");
    }
    false
}
