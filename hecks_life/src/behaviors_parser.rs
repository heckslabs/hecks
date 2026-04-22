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
        loads: vec![],
    };
    let lines: Vec<&str> = source.lines().collect();
    let mut i = 0;

    while i < lines.len() {
        let line = lines[i].trim();

        if line.starts_with("Hecks.behaviors") {
            if let Some(name) = extract_string(line) { suite.name = name; }
        } else if line.starts_with("vision") {
            if let Some(v) = extract_string(line) { suite.vision = Some(v); }
        } else if line.starts_with("loads ") || line.starts_with("loads\t") || line == "loads" {
            // `loads "a", "b", "c"` — zero or more quoted names. Empty
            // `loads` with no arguments records nothing (same as absent).
            for name in extract_all_strings(line) {
                suite.loads.push(name);
            }
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

/// Return every double-quoted substring on `line`, in source order. Used
/// to pluck the variadic `"a", "b", "c"` argument list of `loads` and
/// `then_events_include`. Honors backslash-escaped quotes inside strings.
fn extract_all_strings(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let bytes = line.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'"' {
            let mut j = i + 1;
            let mut buf = String::new();
            while j < bytes.len() && bytes[j] != b'"' {
                if bytes[j] == b'\\' && j + 1 < bytes.len() {
                    buf.push(bytes[j + 1] as char);
                    j += 2;
                } else {
                    buf.push(bytes[j] as char);
                    j += 1;
                }
            }
            if j < bytes.len() {
                out.push(buf);
                i = j + 1;
                continue;
            } else {
                break;
            }
        }
        i += 1;
    }
    out
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

#[cfg(test)]
mod tests {
    use super::*;

    fn suite_src(body: &str) -> String {
        format!(
            "Hecks.behaviors \"Pizzas\" do\n  vision \"v\"\n{}end\n",
            body
        )
    }

    #[test]
    fn loads_single_name_records_one_entry() {
        let src = suite_src("  loads \"pulse\"\n");
        let suite = parse(&src);
        assert_eq!(suite.loads, vec!["pulse".to_string()]);
    }

    #[test]
    fn loads_multiple_names_records_them_in_order() {
        let src = suite_src("  loads \"body\", \"being\", \"sleep\"\n");
        let suite = parse(&src);
        assert_eq!(
            suite.loads,
            vec!["body".to_string(), "being".to_string(), "sleep".to_string()]
        );
    }

    #[test]
    fn no_loads_line_leaves_loads_empty() {
        let src = suite_src(
            "  test \"Create sets name\" do\n    \
              tests \"CreatePizza\", on: \"Pizza\"\n    \
              input  name: \"M\"\n    \
              expect name: \"M\"\n  end\n",
        );
        let suite = parse(&src);
        assert!(suite.loads.is_empty(), "loads should default to empty");
    }

    #[test]
    fn then_events_include_single_name_records_one_entry() {
        let src = suite_src(
            "  test \"Cascade fires\" do\n    \
              tests \"Tick\", on: \"Mindstream\"\n    \
              input  at: \"T0\"\n    \
              then_events_include \"BodyPulse\"\n  end\n",
        );
        let suite = parse(&src);
        assert_eq!(suite.tests.len(), 1);
        assert_eq!(suite.tests[0].events_include, vec!["BodyPulse".to_string()]);
    }

    #[test]
    fn then_events_include_multiple_names_in_order() {
        let src = suite_src(
            "  test \"Cascade fires\" do\n    \
              tests \"Tick\", on: \"Mindstream\"\n    \
              input  at: \"T0\"\n    \
              then_events_include \"BodyPulse\", \"FatigueAccumulated\", \"SynapsesPruned\"\n  end\n",
        );
        let suite = parse(&src);
        assert_eq!(
            suite.tests[0].events_include,
            vec![
                "BodyPulse".to_string(),
                "FatigueAccumulated".to_string(),
                "SynapsesPruned".to_string(),
            ]
        );
    }

    #[test]
    fn no_then_events_include_leaves_events_include_empty() {
        let src = suite_src(
            "  test \"Plain\" do\n    \
              tests \"CreatePizza\", on: \"Pizza\"\n    \
              input  name: \"M\"\n    \
              expect name: \"M\"\n  end\n",
        );
        let suite = parse(&src);
        assert!(suite.tests[0].events_include.is_empty());
    }

    #[test]
    fn suite_with_loads_plus_mixed_tests() {
        // Suite-level loads, one test with then_events_include, another without.
        let src = "Hecks.behaviors \"Mindstream\" do\n  \
          vision \"v\"\n  \
          loads \"pulse\", \"body\"\n  \
          test \"Fans out\" do\n    \
            tests \"Tick\", on: \"Mindstream\"\n    \
            input  at: \"T0\"\n    \
            then_events_include \"BodyPulse\", \"FatigueAccumulated\"\n  \
          end\n  \
          test \"Plain\" do\n    \
            tests \"CreateNote\", on: \"Mindstream\"\n    \
            input  body: \"hi\"\n    \
            expect body: \"hi\"\n  \
          end\n\
          end\n";
        let suite = parse(src);
        assert_eq!(
            suite.loads,
            vec!["pulse".to_string(), "body".to_string()]
        );
        assert_eq!(suite.tests.len(), 2);
        assert_eq!(
            suite.tests[0].events_include,
            vec!["BodyPulse".to_string(), "FatigueAccumulated".to_string()]
        );
        assert!(suite.tests[1].events_include.is_empty());
    }

    #[test]
    fn extract_all_strings_handles_multiple_tokens() {
        assert_eq!(
            extract_all_strings("loads \"a\", \"b\", \"c\""),
            vec!["a".to_string(), "b".to_string(), "c".to_string()]
        );
    }

    #[test]
    fn extract_all_strings_empty_when_no_quotes() {
        let r: Vec<String> = extract_all_strings("loads");
        assert!(r.is_empty());
    }
}
