//! JSON helpers — minimal JSON serialization and parsing
//!
//! Zero-dependency JSON for the HTTP server. Parses dispatch bodies
//! and serializes Values, aggregates, and events to JSON strings.

use crate::runtime::Value;
use std::collections::HashMap;

/// Parse dispatch body: { "command": "Name", "attrs": { "k": "v" } }
pub fn parse_dispatch_body(body: &str) -> (String, HashMap<String, Value>) {
    let body = body.trim();
    let mut command = String::new();
    let mut attrs = HashMap::new();

    if let Some(idx) = body.find("\"command\"") {
        let rest = &body[idx + 9..];
        if let Some(val) = extract_json_string(rest) {
            command = val;
        }
    }

    if let Some(idx) = body.find("\"attrs\"") {
        let rest = &body[idx + 7..];
        if let Some(brace_start) = rest.find('{') {
            let inner = &rest[brace_start + 1..];
            if let Some(brace_end) = inner.find('}') {
                let pairs = &inner[..brace_end];
                for pair in split_json_pairs(pairs) {
                    let pair = pair.trim();
                    if let Some(colon) = pair.find(':') {
                        let key = pair[..colon].trim().trim_matches('"');
                        let val_str = pair[colon + 1..].trim();
                        attrs.insert(key.to_string(), parse_json_value(val_str));
                    }
                }
            }
        }
    }

    (command, attrs)
}

fn extract_json_string(s: &str) -> Option<String> {
    let start = s.find('"')? + 1;
    let end = s[start..].find('"')? + start;
    Some(s[start..end].to_string())
}

fn split_json_pairs(s: &str) -> Vec<&str> {
    let mut pairs = vec![];
    let mut depth = 0;
    let mut last = 0;
    for (i, c) in s.char_indices() {
        match c {
            '{' | '[' => depth += 1,
            '}' | ']' => depth -= 1,
            ',' if depth == 0 => {
                pairs.push(&s[last..i]);
                last = i + 1;
            }
            _ => {}
        }
    }
    if last < s.len() {
        pairs.push(&s[last..]);
    }
    pairs
}

fn parse_json_value(s: &str) -> Value {
    let s = s.trim();
    if s.starts_with('"') && s.ends_with('"') {
        Value::Str(s[1..s.len() - 1].to_string())
    } else if let Ok(n) = s.parse::<i64>() {
        Value::Int(n)
    } else if s == "true" {
        Value::Bool(true)
    } else if s == "false" {
        Value::Bool(false)
    } else if s == "null" {
        Value::Null
    } else {
        Value::Str(s.to_string())
    }
}

pub fn value_to_json(v: &Value) -> String {
    match v {
        Value::Str(s) => format!(r#""{}""#, s.replace('"', "\\\"")),
        Value::Int(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Null => "null".to_string(),
        Value::List(items) => {
            let inner: Vec<String> = items.iter().map(value_to_json).collect();
            format!("[{}]", inner.join(","))
        }
        Value::Map(m) => {
            let fields: Vec<String> = m.iter()
                .map(|(k, v)| format!(r#""{}": {}"#, k, value_to_json(v)))
                .collect();
            format!("{{{}}}", fields.join(","))
        }
    }
}

pub fn value_map_to_json(fields: &HashMap<String, Value>) -> String {
    let pairs: Vec<String> = fields.iter()
        .map(|(k, v)| format!(r#""{}": {}"#, k, value_to_json(v)))
        .collect();
    pairs.join(",")
}

pub fn json_str(s: &str) -> String {
    format!(r#""{}""#, s.replace('"', "\\\""))
}
