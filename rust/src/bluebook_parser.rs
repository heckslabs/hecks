//! bluebook_parser - reads a .bluebook file into the IR.
//!
//! BOTH RUNTIMES READ THE NATIVE FORMAT. Handing Rust a JSON IR that Ruby had
//! already parsed was a scaffold; this is the thing it was standing in for.
//!
//! Two parsers is not the mistake - two parsers AUTHORED TWICE BY HAND, kept
//! in step by a suite that can only detect drift after the fact, is the
//! mistake. This one is written to be REPLACED by a projection of the Ruby
//! parser, and until then bin/parity feeds the same source file to both and
//! compares the answers, so drift shows up as a wrong answer rather than as a
//! diff nobody reads.
//!
//! It produces exactly the shape the exporter produces, so everything
//! downstream is unchanged and the two paths stay comparable.
//!
//! An unrecognised line is REFUSED, never skipped. A parser that silently
//! ignores what it does not understand will happily read half a domain and
//! report success.

use crate::bluebook_lines::*;
use serde_json::{json, Map, Value};

struct Cursor {
    lines: Vec<String>,
    at: usize,
}

impl Cursor {
    fn next(&mut self) -> Option<String> {
        while self.at < self.lines.len() {
            let line = self.lines[self.at].trim().to_string();
            self.at += 1;
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            return Some(line);
        }
        None
    }
}

pub fn parse(source: &str) -> Result<Value, String> {
    let mut cursor = Cursor {
        lines: source.lines().map(str::to_string).collect(),
        at: 0,
    };

    while let Some(line) = cursor.next() {
        if line.starts_with("Hecks.bluebook") {
            let name = quoted(&line).ok_or("Hecks.bluebook has no name")?;
            let bluebook = parse_bluebook(&mut cursor, &name)?;
            let mut domains = Map::new();
            domains.insert(name, bluebook);
            return Ok(Value::Object(domains));
        }
    }
    Err("no Hecks.bluebook declaration found".to_string())
}

fn parse_bluebook(cursor: &mut Cursor, name: &str) -> Result<Value, String> {
    let mut vision = Value::Null;
    let mut aggregates: Vec<Value> = vec![];

    while let Some(line) = cursor.next() {
        if closes_block(&line) {
            break;
        }
        if line.starts_with("vision") {
            vision = Value::String(quoted(&line).unwrap_or_default());
        } else if line.starts_with("aggregate") {
            let aggregate_name = quoted(&line).ok_or("aggregate has no name")?;
            aggregates.push(parse_aggregate(cursor, &aggregate_name)?);
        } else if matches!(line.as_str(), "core" | "supporting" | "generic") {
            // Strategic classification - recorded in Ruby, not needed to run.
        } else {
            return Err(format!("unrecognised line in bluebook: {}", line));
        }
    }

    Ok(json!({ "name": name, "vision": vision, "aggregates": aggregates }))
}

fn parse_aggregate(cursor: &mut Cursor, name: &str) -> Result<Value, String> {
    let mut description = Value::Null;
    let mut identified_by = "id".to_string();
    let mut attributes: Vec<Value> = vec![];
    let mut value_objects: Vec<Value> = vec![];
    let mut commands: Vec<Value> = vec![];

    while let Some(line) = cursor.next() {
        if closes_block(&line) {
            break;
        }
        if line.starts_with("description") {
            description = Value::String(quoted(&line).unwrap_or_default());
        } else if line.starts_with("identified_by") {
            identified_by = symbol(&line).unwrap_or_else(|| "id".to_string());
        } else if line.starts_with("attribute") {
            attributes.push(parse_attribute(&line)?);
        } else if line.starts_with("reference_to") {
            let target = line["reference_to".len()..].trim().to_string();
            attributes.push(json!({
                "name": format!("{}_id", snake(&target)),
                "type": "String", "list": false, "default": Value::Null
            }));
        } else if line.starts_with("value_object") {
            let vo_name = quoted(&line).ok_or("value_object has no name")?;
            value_objects.push(parse_value_object(cursor, &vo_name)?);
        } else if line.starts_with("command") {
            let command_name = quoted(&line).ok_or("command has no name")?;
            commands.push(parse_command(cursor, &command_name)?);
        } else {
            return Err(format!("unrecognised line in aggregate {}: {}", name, line));
        }
    }

    Ok(json!({
        "name": name,
        "description": description,
        "identified_by": identified_by,
        "attributes": attributes,
        "value_objects": value_objects,
        "commands": commands
    }))
}

fn parse_attribute(line: &str) -> Result<Value, String> {
    let name = symbol(line).ok_or_else(|| format!("attribute has no name: {}", line))?;
    let (kind, is_list) = attribute_type(line);

    Ok(json!({
        "name": name,
        "type": kind,
        "list": is_list,
        "default": default_value(line).unwrap_or(Value::Null)
    }))
}

fn parse_value_object(cursor: &mut Cursor, name: &str) -> Result<Value, String> {
    let mut attributes: Vec<Value> = vec![];
    let mut invariants: Vec<Value> = vec![];

    while let Some(line) = cursor.next() {
        if closes_block(&line) {
            break;
        }
        if line.starts_with("attribute") {
            attributes.push(parse_attribute(&line)?);
        } else if line.starts_with("invariant") {
            invariants.push(parse_predicate(&line, "invariant")?);
        } else {
            return Err(format!("unrecognised line in value_object {}: {}", name, line));
        }
    }

    Ok(json!({ "name": name, "attributes": attributes, "invariants": invariants }))
}

fn parse_command(cursor: &mut Cursor, name: &str) -> Result<Value, String> {
    let mut role = Value::Null;
    let mut goal = Value::Null;
    let mut references = Value::Null;
    let mut attributes: Vec<Value> = vec![];
    let mut givens: Vec<Value> = vec![];
    let mut mutations: Vec<Value> = vec![];
    let mut emits: Vec<Value> = vec![];

    while let Some(line) = cursor.next() {
        if closes_block(&line) {
            break;
        }
        if line.starts_with("role") {
            role = Value::String(quoted(&line).unwrap_or_default());
        } else if line.starts_with("goal") || line.starts_with("description") {
            goal = Value::String(quoted(&line).unwrap_or_default());
        } else if line.starts_with("reference_to") {
            references = Value::String(line["reference_to".len()..].trim().to_string());
        } else if line.starts_with("attribute") {
            attributes.push(parse_attribute(&line)?);
        } else if line.starts_with("given") {
            givens.push(parse_predicate(&line, "given")?);
        } else if line.starts_with("then_set") {
            mutations.push(parse_mutation(&line)?);
        } else if line.starts_with("emits") {
            emits.push(Value::String(quoted(&line).unwrap_or_default()));
        } else {
            return Err(format!("unrecognised line in command {}: {}", name, line));
        }
    }

    Ok(json!({
        "name": name, "role": role, "goal": goal, "references": references,
        "attributes": attributes, "givens": givens,
        "mutations": mutations, "emits": emits
    }))
}

fn parse_predicate(line: &str, keyword: &str) -> Result<Value, String> {
    let description = quoted(line)
        .ok_or_else(|| format!("{} has no description: {}", keyword, line))?;
    let body = brace_body(line)
        .ok_or_else(|| format!("{} has no predicate: {}", keyword, line))?;

    Ok(json!({ "description": description, "canonical": canonicalise(&body) }))
}

/// `then_set :status, to: "sold"` and
/// `then_set :toppings, append: { name: :name }`.
///
/// The argument-vs-literal distinction is decided HERE, where the Ruby source
/// still shows it: a bare `:symbol` reads an argument, anything else is a
/// literal. Reading the native format means this is no longer something the
/// exporter has to encode on Rust's behalf.
fn parse_mutation(line: &str) -> Result<Value, String> {
    let target = symbol(line).ok_or_else(|| format!("then_set has no target: {}", line))?;

    if line.contains("append:") {
        let mut fields = Map::new();
        for (field, argument) in field_map(line) {
            fields.insert(field, Value::String(argument));
        }
        return Ok(json!({ "target": target, "op": "append", "fields": fields }));
    }

    let index = line
        .find("to:")
        .ok_or_else(|| format!("then_set has neither to: nor append: {}", line))?;
    let text = line[index + "to:".len()..].trim().trim_end_matches(',').trim();

    let source = if let Some(name) = text.strip_prefix(':') {
        json!({ "kind": "argument", "name": name })
    } else if text.starts_with('"') {
        json!({ "kind": "literal", "value": quoted(text).unwrap_or_default() })
    } else if let Ok(number) = text.parse::<i64>() {
        json!({ "kind": "literal", "value": number })
    } else {
        json!({ "kind": "literal", "value": text })
    };

    Ok(json!({ "target": target, "op": "set", "source": source }))
}

fn snake(name: &str) -> String {
    let mut out = String::new();
    for (index, character) in name.char_indices() {
        if character.is_uppercase() && index > 0 {
            out.push('_');
        }
        out.extend(character.to_lowercase());
    }
    out
}
