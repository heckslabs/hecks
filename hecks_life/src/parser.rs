//! Bluebook parser — reads .bluebook files into IR
//!
//! Parses the Ruby-hosted DSL by pattern matching on the structure.
//! Not a full Ruby parser — just enough to read Bluebook declarations.
//! Block parsers live in parse_blocks.rs.

use crate::ir::*;
use crate::parser_helpers::*;
use crate::parse_blocks::*;

pub fn parse(source: &str) -> Domain {
    let mut domain = Domain {
        name: String::new(),
        category: None,
        vision: None,
        aggregates: vec![],
        policies: vec![],
        fixtures: vec![],
    };

    let lines: Vec<&str> = source.lines().collect();
    let mut i = 0;

    while i < lines.len() {
        let line = lines[i].trim();

        if line.starts_with("Hecks.bluebook") {
            if let Some(name) = extract_string(line) {
                domain.name = name;
            }
        }

        if line.starts_with("category") && !line.starts_with("category,") {
            if let Some(cat) = extract_string(line) {
                domain.category = Some(cat);
            }
        }

        if line.starts_with("vision") {
            if let Some(v) = extract_string(line) {
                domain.vision = Some(v);
            }
        }

        if line.starts_with("aggregate") {
            let (agg, consumed) = parse_aggregate(&lines[i..]);
            domain.aggregates.push(agg);
            i += consumed;
            continue;
        }

        if line.starts_with("policy") {
            let (policy, consumed) = parse_policy(&lines[i..]);
            domain.policies.push(policy);
            i += consumed;
            continue;
        }

        if line.starts_with("fixture") {
            // Two forms:
            //   1. inline: `fixture "X", a: 1, b: 2` (may span lines via
            //      trailing comma or unclosed brackets);
            //   2. block:  `fixture "X" do ... end` — must consume to the
            //      matching `end` so inner `aggregate` lines aren't picked
            //      up as top-level aggregates.
            if ends_with_do_block(line) {
                // Block form: `fixture "X" do ... end`. The first positional
                // string is the fixture's logical NAME (an identifier);
                // `aggregate "Y"` inside the block declares the aggregate
                // type; every other `key "value"` line becomes an attribute.
                let name = extract_string(line);
                let (aggregate_name, attributes, consumed) =
                    parse_fixture_block_body(&lines[i + 1..]);
                domain.fixtures.push(crate::ir::Fixture {
                    name,
                    aggregate_name,
                    attributes,
                });
                i += consumed;
            } else {
                let mut full = line.to_string();
                while needs_continuation(&full) && i + 1 < lines.len() {
                    i += 1;
                    full.push(' ');
                    full.push_str(lines[i].trim());
                }
                domain.fixtures.push(parse_fixture(&full));
            }
        }

        i += 1;
    }

    domain
}

// True if the line is incomplete and the next physical line is a
// continuation: either trailing comma, or unbalanced brackets/parens/braces
// (outside string literals).
fn needs_continuation(s: &str) -> bool {
    let trimmed = s.trim_end();
    if trimmed.ends_with(',') { return true; }
    let mut depth = 0i32;
    let mut in_str = false;
    let mut prev = '\0';
    for c in s.chars() {
        match c {
            '"' if prev != '\\' => in_str = !in_str,
            '[' | '{' | '(' if !in_str => depth += 1,
            ']' | '}' | ')' if !in_str => depth -= 1,
            _ => {}
        }
        prev = c;
    }
    depth > 0
}

fn parse_aggregate(lines: &[&str]) -> (Aggregate, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let desc = extract_second_string(first);

    let mut agg = Aggregate {
        name, description: desc, attributes: vec![],
        commands: vec![], queries: vec![], value_objects: vec![],
        references: vec![], lifecycle: None,
    };

    let mut i = 1;
    let mut depth = 1;

    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();

        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
            i += 1;
            continue;
        }

        if depth == 1 {
            if line.starts_with("command") || is_shorthand_command(line) {
                let (cmd, consumed) = parse_command(&lines[i..]);
                agg.commands.push(cmd);
                i += consumed;
                continue;
            } else if line.starts_with("value_object") {
                let (vo, consumed) = parse_value_object(&lines[i..]);
                agg.value_objects.push(vo);
                i += consumed;
                continue;
            } else if line.starts_with("attribute") {
                if let Some(attr) = parse_attribute(line) {
                    agg.attributes.push(attr);
                }
                if ends_with_do_block(line) { depth += 1; }
            } else if line.starts_with("description") {
                agg.description = extract_string(line);
            } else if line.starts_with("reference_to") {
                // Two forms: `reference_to Pizza` (spaced) and `reference_to(Pizza)` /
                // `reference_to(Pizza, role: :foo)` (paren). Delegate the paren form
                // to parse_shorthand_reference so we honor `role:` and `.as()`.
                if line.starts_with("reference_to(") {
                    if let Some(r) = parse_shorthand_reference(line) {
                        agg.references.push(r);
                    }
                } else if let Some(target) = extract_word_after(line, "reference_to") {
                    let snake = to_snake_case(&target);
                    agg.references.push(Reference { name: snake, target, domain: None });
                }
            } else if line.starts_with("lifecycle") {
                let (lc, consumed) = parse_lifecycle(&lines[i..]);
                agg.lifecycle = Some(lc);
                i += consumed;
                continue;
            } else if is_shorthand_line(line) {
                match parse_shorthand(line) {
                    ShorthandResult::Attribute(a) => agg.attributes.push(a),
                    ShorthandResult::Reference(r) => agg.references.push(r),
                    ShorthandResult::None => {}
                }
            } else if line.starts_with("query") {
                let name = extract_string(line).unwrap_or_else(|| {
                    line.split_whitespace().nth(1).unwrap_or("").trim_matches('"').to_string()
                });
                let desc = extract_second_string(line);
                agg.queries.push(Query { name, description: desc });
                if ends_with_do_block(line) { depth += 1; }
            } else if ends_with_do_block(line) {
                depth += 1;
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }

        i += 1;
    }

    (agg, i + 1)
}
