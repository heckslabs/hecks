//! Parser for .fixtures files. Surface (kept small):
//!
//!   Hecks.fixtures "Pizzas" do
//!     aggregate "Pizza" do
//!       fixture "Margherita", name: "Margherita", description: "Classic"
//!       fixture "Pepperoni",  name: "Pepperoni",  description: "Spicy"
//!     end
//!     aggregate "Order" do
//!       fixture "PendingOrder", customer_name: "Sample", quantity: 1
//!     end
//!   end
//!
//! `fixture "Label", k: v, k2: v2` reuses the same comma-separated kwarg
//! parser as the bluebook IR's inline form (see parse_blocks::parse_fixture's
//! split_top_level_commas), so values can themselves contain commas
//! (quoted strings, arrays, hashes).
//!
//! The first positional arg of `fixture` is the label (Fixture::name);
//! everything after is k:v attributes. The enclosing `aggregate "X"`
//! block sets aggregate_name on each fixture inside.

use crate::fixtures_ir::FixturesFile;
use crate::ir::Fixture;
use crate::parser_helpers::{extract_string, ends_with_do_block};

pub fn parse(source: &str) -> FixturesFile {
    let mut file = FixturesFile {
        domain_name: String::new(),
        fixtures: vec![],
        catalogs: std::collections::BTreeMap::new(),
    };
    let lines: Vec<&str> = source.lines().collect();
    let mut i = 0;
    let mut current_agg: Option<String> = None;
    let mut depth: usize = 0;

    while i < lines.len() {
        let line = lines[i].trim();
        if line.starts_with('#') || line.is_empty() { i += 1; continue; }

        if line.starts_with("Hecks.fixtures") {
            if let Some(name) = extract_string(line) { file.domain_name = name; }
            depth += 1;
        } else if line.starts_with("aggregate ") && ends_with_do_block(line) {
            current_agg = extract_string(line);
            depth += 1;
        } else if line.starts_with("fixture ") {
            if let Some(agg) = &current_agg {
                file.fixtures.push(parse_fixture_line(line, agg));
            }
        } else if line == "end" {
            if depth > 0 { depth -= 1; }
            // Closing the `aggregate` block clears the current aggregate.
            // Closing the outer `Hecks.fixtures` leaves depth at 0.
            if depth == 1 { current_agg = None; }
        }
        i += 1;
    }

    file
}

/// Parse a single `fixture "Label", k: v, …` line, returning a Fixture
/// whose aggregate_name is the enclosing `aggregate "X"` block's name.
fn parse_fixture_line(line: &str, aggregate_name: &str) -> Fixture {
    let label = extract_string(line);
    let mut attributes: Vec<(String, String)> = vec![];

    if let Some(comma_pos) = line.find(',') {
        let rest = &line[comma_pos + 1..];
        for part in split_top_level_commas(rest) {
            let part = part.trim();
            if let Some(colon) = part.find(':') {
                let key = part[..colon].trim().to_string();
                let raw = part[colon + 1..].trim();
                let val = if raw.starts_with('"') {
                    extract_string(raw).unwrap_or_else(|| raw.to_string())
                } else {
                    raw.to_string()
                };
                attributes.push((key, val));
            }
        }
    }

    Fixture {
        name: label,
        aggregate_name: aggregate_name.to_string(),
        attributes,
    }
}

/// Split on `,` at depth 0 — ignoring commas inside strings/brackets.
/// Mirrors parse_blocks::split_top_level_commas (kept private to each
/// parser to avoid forcing a public helper).
fn split_top_level_commas(s: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut start = 0;
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i] as char;
        match c {
            '"' if !escaped_at(s, i) => in_str = !in_str,
            '[' | '{' | '(' if !in_str => depth += 1,
            ']' | '}' | ')' if !in_str => depth -= 1,
            ',' if !in_str && depth == 0 => {
                parts.push(&s[start..i]);
                start = i + 1;
            }
            _ => {}
        }
        i += 1;
    }
    parts.push(&s[start..]);
    parts
}

fn escaped_at(s: &str, i: usize) -> bool {
    if i == 0 { return false; }
    let bytes = s.as_bytes();
    let mut count = 0;
    let mut j = i;
    while j > 0 && bytes[j - 1] == b'\\' {
        count += 1;
        j -= 1;
    }
    count % 2 == 1
}
