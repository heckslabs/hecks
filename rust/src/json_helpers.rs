//! JSON helpers — minimal JSON serialization and parsing
//!
//! Zero-dependency JSON for the HTTP server. Parses dispatch bodies
//! and serializes Values, aggregates, and events to JSON strings.

use crate::runtime::Value;
use std::collections::HashMap;

/// Parse dispatch body: { "command": "Name", "attrs": { "k": v, ... } }.
/// Parsed with serde_json so NESTED value objects survive as `Value::Map`
/// (arrays as `Value::List`) end-to-end. The previous hand-rolled parser found
/// the attrs object's end with the FIRST `}` — a nested VO's brace — truncating
/// `Money {cents, currency}` to a broken string, and stringified every nested
/// object (type loss), so `amount.cents > 0` always failed. Now the structure
/// rides through dispatch, event, and storage intact.
pub fn parse_dispatch_body(body: &str) -> (String, HashMap<String, Value>) {
    let parsed: serde_json::Value =
        serde_json::from_str(body.trim()).unwrap_or(serde_json::Value::Null);
    let command = parsed
        .get("command")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let attrs = parsed
        .get("attrs")
        .and_then(|v| v.as_object())
        .map(|m| {
            m.iter()
                .map(|(k, v)| (k.clone(), json_value_to_runtime(v)))
                .collect()
        })
        .unwrap_or_default();
    (command, attrs)
}

/// Decode a serde_json value into a runtime `Value`, RECURSIVELY : nested
/// objects -> `Value::Map`, arrays -> `Value::List`, so a value object keeps its
/// shape instead of collapsing to a string. A whole-number decodes to `Int` ;
/// any other number falls back to its string form (the `Value` enum has no
/// float), mirroring repository::from_json and json_to_value_recursive.
fn json_value_to_runtime(v: &serde_json::Value) -> Value {
    match v {
        serde_json::Value::String(s) => Value::Str(s.clone()),
        serde_json::Value::Bool(b) => Value::Bool(*b),
        serde_json::Value::Number(n) => n
            .as_i64()
            .map(Value::Int)
            .unwrap_or_else(|| Value::Str(n.to_string())),
        serde_json::Value::Null => Value::Null,
        serde_json::Value::Array(a) => {
            Value::List(a.iter().map(json_value_to_runtime).collect())
        }
        serde_json::Value::Object(m) => Value::Map(
            m.iter()
                .map(|(k, v)| (k.clone(), json_value_to_runtime(v)))
                .collect(),
        ),
    }
}

/// Top-level keys of a JSON object body — used by the HTTP door to
/// reject unknown keys LOUDLY. A silently-ignored "args" key once let an
/// attribute-less command through and minted phantom records ; the door
/// must argue like the MCP door does, never swallow.
pub fn top_level_keys(body: &str) -> Vec<String> {
    let body = body.trim();
    let inner = match (body.find('{'), body.rfind('}')) {
        (Some(s), Some(e)) if e > s => &body[s + 1..e],
        _ => return vec![],
    };
    split_json_pairs(inner)
        .iter()
        .filter_map(|pair| {
            let pair = pair.trim();
            let colon = pair.find(':')?;
            Some(pair[..colon].trim().trim_matches('"').to_string())
        })
        .collect()
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
    // A proper JSON string encoder : escape the quote, the backslash, and
    // the control characters (newline / tab / …) that strict parsers
    // (browsers' JSON.parse, Python's json) reject raw. Before 2026-07-19
    // this only escaped `"`, so any multi-line or backslash-bearing value
    // (e.g. the /source raw-bluebook route) emitted invalid JSON.
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
