//! Bluebook parser — reads .bluebook files into IR
//!
//! Parses the Ruby-hosted DSL by pattern matching on the structure.
//! Not a full Ruby parser — just enough to read Bluebook declarations.
//! Block parsers live in parse_blocks.rs.
//!
//! [antibody-exempt: parser.rs — kernel-surface bluebook parser;
//!  hecks-life specialize parser regenerates this file byte-for-byte from
//!  parser_shape fixtures. Edit here seeds the golden fixture; update
//!  parser_shape to match. Subsumes unique:true singleton pattern via
//!  identified_by natural-key dispatch.]

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
        entrypoint: None,
        sections: vec![],
    };

    let source = strip_shebang(source);

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

        if line.starts_with("entrypoint") {
            if let Some(ep) = extract_string(line) {
                domain.entrypoint = Some(ep);
            }
        }

        if line.starts_with("aggregate") {
            let (agg, consumed) = parse_aggregate(&lines[i..]);
            domain.aggregates.push(agg);
            i += consumed;
            continue;
        }

        if line.starts_with("section ") || line.starts_with("section\t") {
            let (sec, consumed) = parse_section(&lines[i..]);
            domain.sections.push(sec);
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
            if ends_with_do_block(line) {
                let mut depth = 1;
                while i + 1 < lines.len() && depth > 0 {
                    i += 1;
                    let l = lines[i].trim();
                    if l == "end" { depth -= 1; }
                    else if ends_with_do_block(l) { depth += 1; }
                }
            }
        }

        i += 1;
    }

    domain
}

/// Strip a leading `#!...\n` shebang line if present.
///
/// Bluebooks carrying `#!/usr/bin/env hecks-life run` at the top should
/// parse identically to the same file without that line. Everything
/// after the first newline passes through untouched.
pub fn strip_shebang(source: &str) -> &str {
    if source.starts_with("#!") {
        if let Some(nl) = source.find('\n') {
            return &source[nl + 1..];
        }
        return "";
    }
    source
}

fn parse_aggregate(lines: &[&str]) -> (Aggregate, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let desc = extract_second_string(first);

    let mut agg = Aggregate {
        name, description: desc, attributes: vec![],
        commands: vec![], queries: vec![], value_objects: vec![],
        entities: vec![],
        references: vec![], lifecycle: None, identified_by: None,
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
            } else if line.starts_with("entity") {
                let (ent, consumed) = parse_entity(&lines[i..]);
                agg.entities.push(ent);
                i += consumed;
                continue;
            } else if line.starts_with("attribute") {
                if let Some(attr) = parse_attribute(line) { agg.attributes.push(attr); }
                if ends_with_do_block(line) { depth += 1; }
            } else if line.starts_with("description") {
                agg.description = extract_string(line);
            } else if line.starts_with("reference_to") {
                absorb_reference_to(line, &mut agg);
            } else if line.starts_with("lifecycle") {
                let (lc, consumed) = parse_lifecycle(&lines[i..]);
                agg.lifecycle = Some(lc);
                i += consumed;
                continue;
            } else if line.starts_with("identified_by") {
                agg.identified_by = extract_symbol(line);
            } else if is_shorthand_line(line) {
                absorb_shorthand(line, &mut agg);
            } else if line.starts_with("query") {
                push_query(line, &mut agg, &mut depth);
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

fn absorb_reference_to(line: &str, agg: &mut Aggregate) {
    if line.starts_with("reference_to(") {
        if let Some(r) = parse_shorthand_reference(line) {
            agg.references.push(r);
        }
    } else if let Some(target) = extract_word_after(line, "reference_to") {
        let name = if let Some(pos) = line.find(", as:") {
            let after = &line[pos + ", as:".len()..];
            extract_symbol(after).unwrap_or_else(|| to_snake_case(&target))
        } else if let Some(pos) = line.find(", role:") {
            let after = &line[pos + ", role:".len()..];
            extract_symbol(after).unwrap_or_else(|| to_snake_case(&target))
        } else {
            to_snake_case(&target)
        };
        agg.references.push(Reference { name, target, domain: None });
    }
}

fn absorb_shorthand(line: &str, agg: &mut Aggregate) {
    match parse_shorthand(line) {
        ShorthandResult::Attribute(a) => agg.attributes.push(a),
        ShorthandResult::Reference(r) => agg.references.push(r),
        ShorthandResult::None => {}
    }
}

fn push_query(line: &str, agg: &mut Aggregate, depth: &mut usize) {
    let name = extract_string(line).unwrap_or_else(|| {
        line.split_whitespace().nth(1).unwrap_or("").trim_matches('"').to_string()
    });
    let desc = extract_second_string(line);
    agg.queries.push(Query { name, description: desc });
    if ends_with_do_block(line) { *depth += 1; }
}

// True if the line is incomplete and the next physical line is a
// continuation: either trailing comma, or unbalanced brackets/parens/braces
// (outside string literals).
#[allow(dead_code)]
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
