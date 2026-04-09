//! Bluebook parser — reads .bluebook files into IR
//!
//! Parses the Ruby-hosted DSL by pattern matching on the structure.
//! Not a full Ruby parser — just enough to read Bluebook declarations.

use crate::ir::*;

pub fn parse(source: &str) -> Domain {
    let mut domain = Domain {
        name: String::new(),
        aggregates: vec![],
        policies: vec![],
    };

    let lines: Vec<&str> = source.lines().collect();
    let mut i = 0;

    while i < lines.len() {
        let line = lines[i].trim();

        // Domain declaration
        if line.starts_with("Hecks.bluebook") {
            if let Some(name) = extract_string(line) {
                domain.name = name;
            }
        }

        // Aggregate
        if line.starts_with("aggregate") {
            let (agg, consumed) = parse_aggregate(&lines[i..]);
            domain.aggregates.push(agg);
            i += consumed;
            continue;
        }

        // Policy
        if line.starts_with("policy") {
            let (policy, consumed) = parse_policy(&lines[i..]);
            domain.policies.push(policy);
            i += consumed;
            continue;
        }

        i += 1;
    }

    domain
}

fn parse_aggregate(lines: &[&str]) -> (Aggregate, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let desc = extract_second_string(first);

    let mut agg = Aggregate {
        name,
        description: desc,
        attributes: vec![],
        commands: vec![],
        value_objects: vec![],
        references: vec![],
    };

    let mut i = 1;
    let mut depth = 1;

    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();

        if line.contains(" do") || line.ends_with(" do") {
            depth += 1;
        }
        if line == "end" || line.ends_with("end") && !line.contains("\"end") {
            depth -= 1;
            if depth == 0 { break; }
        }

        if depth == 1 {
            if line.starts_with("attribute") {
                if let Some(attr) = parse_attribute(line) {
                    agg.attributes.push(attr);
                }
            } else if line.starts_with("command") {
                let (cmd, consumed) = parse_command(&lines[i..]);
                agg.commands.push(cmd);
                i += consumed;
                continue;
            } else if line.starts_with("value_object") {
                let (vo, consumed) = parse_value_object(&lines[i..]);
                agg.value_objects.push(vo);
                i += consumed;
                continue;
            } else if line.starts_with("reference_to") {
                if let Some(target) = extract_word_after(line, "reference_to") {
                    let snake = to_snake_case(&target);
                    agg.references.push(Reference {
                        name: snake,
                        target,
                        domain: None,
                    });
                }
            }
        }

        i += 1;
    }

    (agg, i + 1)
}

fn parse_command(lines: &[&str]) -> (Command, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();

    let mut cmd = Command {
        name,
        description: None,
        role: None,
        attributes: vec![],
        references: vec![],
        emits: None,
        givens: vec![],
        mutations: vec![],
    };

    // Single-line command
    if first.contains("{") && first.contains("}") {
        parse_inline_command(first, &mut cmd);
        return (cmd, 1);
    }

    let mut i = 1;
    let mut depth = 1;

    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();

        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
        }

        if line.starts_with("attribute") {
            if let Some(attr) = parse_attribute(line) {
                cmd.attributes.push(attr);
            }
        } else if line.starts_with("role") {
            cmd.role = extract_string(line);
        } else if line.starts_with("description") {
            cmd.description = extract_string(line);
        } else if line.starts_with("emits") {
            cmd.emits = extract_string(line);
        } else if line.starts_with("reference_to") {
            if let Some(target) = extract_word_after(line, "reference_to") {
                let snake = to_snake_case(&target);
                cmd.references.push(Reference {
                    name: snake,
                    target,
                    domain: None,
                });
            }
        } else if line.starts_with("given") {
            let msg = extract_string(line);
            let expr = extract_block(line).unwrap_or_default();
            cmd.givens.push(Given {
                expression: expr,
                message: msg,
            });
        } else if line.starts_with("then_set") {
            if let Some(mutation) = parse_mutation(line) {
                cmd.mutations.push(mutation);
            }
        } else if line.starts_with("then_toggle") {
            if let Some(field) = extract_symbol(line) {
                cmd.mutations.push(Mutation {
                    field,
                    operation: MutationOp::Toggle,
                    value: String::new(),
                });
            }
        }

        i += 1;
    }

    (cmd, i + 1)
}

fn parse_inline_command(line: &str, cmd: &mut Command) {
    // Parse: command("Name") { role "X"; attribute :y, Type; emits "Z" }
    if let Some(block) = extract_block(line) {
        for part in block.split(';') {
            let part = part.trim();
            if part.starts_with("role") {
                cmd.role = extract_string(part);
            } else if part.starts_with("emits") {
                cmd.emits = extract_string(part);
            } else if part.starts_with("attribute") {
                if let Some(attr) = parse_attribute(part) {
                    cmd.attributes.push(attr);
                }
            } else if part.starts_with("reference_to") {
                if let Some(target) = extract_word_after(part, "reference_to") {
                    let snake = to_snake_case(&target);
                    cmd.references.push(Reference {
                        name: snake,
                        target,
                        domain: None,
                    });
                }
            }
        }
    }
}

fn parse_value_object(lines: &[&str]) -> (ValueObject, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();

    let mut vo = ValueObject {
        name,
        description: None,
        attributes: vec![],
    };

    let mut i = 1;
    let mut depth = 1;

    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();
        if line == "end" { depth -= 1; if depth == 0 { break; } }
        if line.starts_with("description") { vo.description = extract_string(line); }
        if line.starts_with("attribute") {
            if let Some(attr) = parse_attribute(line) {
                vo.attributes.push(attr);
            }
        }
        i += 1;
    }

    (vo, i + 1)
}

fn parse_policy(lines: &[&str]) -> (Policy, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut on_event = String::new();
    let mut trigger = String::new();

    let mut i = 1;
    while i < lines.len() {
        let line = lines[i].trim();
        if line == "end" { break; }
        if line.starts_with("on") { on_event = extract_string(line).unwrap_or_default(); }
        if line.starts_with("trigger") { trigger = extract_string(line).unwrap_or_default(); }
        i += 1;
    }

    (Policy { name, on_event, trigger_command: trigger }, i + 1)
}

fn parse_attribute(line: &str) -> Option<Attribute> {
    // attribute :name, Type, default: "value"
    let parts: Vec<&str> = line.splitn(3, ',').collect();
    let first = parts.first()?.trim();
    let name = extract_symbol(first)?;
    let attr_type = if parts.len() > 1 {
        parts[1].trim().to_string()
    } else {
        "String".to_string()
    };
    let list = line.contains("list_of");
    let default = if line.contains("default:") {
        extract_after(line, "default:")
    } else {
        None
    };

    Some(Attribute { name, attr_type, default, list })
}

fn parse_mutation(line: &str) -> Option<Mutation> {
    let field = extract_symbol(line)?;
    let (op, value) = if line.contains("append:") {
        (MutationOp::Append, extract_after(line, "append:")?)
    } else if line.contains("increment:") {
        (MutationOp::Increment, extract_after(line, "increment:")?)
    } else if line.contains("decrement:") {
        (MutationOp::Decrement, extract_after(line, "decrement:")?)
    } else if line.contains("to:") {
        (MutationOp::Set, extract_after(line, "to:")?)
    } else {
        return None;
    };

    Some(Mutation { field, operation: op, value })
}

// --- String extraction helpers ---

fn extract_string(line: &str) -> Option<String> {
    let start = line.find('"')? + 1;
    let end = line[start..].find('"')? + start;
    Some(line[start..end].to_string())
}

fn extract_second_string(line: &str) -> Option<String> {
    let first_end = line.find('"')? + 1;
    let after_first = line[first_end..].find('"')? + first_end + 1;
    let start = line[after_first..].find('"')? + after_first + 1;
    let end = line[start..].find('"')? + start;
    Some(line[start..end].to_string())
}

fn extract_symbol(line: &str) -> Option<String> {
    let start = line.find(':')? + 1;
    let rest = &line[start..];
    let end = rest.find(|c: char| !c.is_alphanumeric() && c != '_').unwrap_or(rest.len());
    let sym = rest[..end].trim().to_string();
    if sym.is_empty() { None } else { Some(sym) }
}

fn extract_word_after(line: &str, keyword: &str) -> Option<String> {
    let start = line.find(keyword)? + keyword.len();
    let rest = line[start..].trim();
    let end = rest.find(|c: char| !c.is_alphanumeric() && c != '_' && c != ':').unwrap_or(rest.len());
    let word = rest[..end].trim().to_string();
    if word.is_empty() { None } else { Some(word) }
}

fn extract_block(line: &str) -> Option<String> {
    let start = line.find('{')? + 1;
    let end = line.rfind('}')?;
    Some(line[start..end].trim().to_string())
}

fn extract_after(line: &str, keyword: &str) -> Option<String> {
    let start = line.find(keyword)? + keyword.len();
    let rest = line[start..].trim();
    Some(rest.trim_end_matches(|c: char| c == ',' || c == ' ').to_string())
}

fn to_snake_case(s: &str) -> String {
    let mut result = String::new();
    for (i, c) in s.chars().enumerate() {
        if c.is_uppercase() && i > 0 {
            result.push('_');
        }
        result.push(c.to_lowercase().next().unwrap());
    }
    result
}
