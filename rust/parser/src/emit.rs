//! JSON writer — Stage 1 stub. Nothing in this crate constructs a real
//! `ir::Bluebook` yet (every parse/*.rs handler stubs out first), so this
//! module has nothing real to serialize; it exists as the named target
//! Stage 2 fills in, matching `JSON.pretty_generate(Exporter.call(...))`
//! byte-for-byte.
//!
//! KNOWN, DEFERRED HAZARD — flagged here rather than solved now: the
//! `json` gem's `JSON.pretty_generate([])` renders differently across
//! versions bundler resolves (`"[]"` on json 2.21.2, `"[\n\n  ]"` under
//! bundler on json 2.7.2) for an EMPTY array specifically. Every real
//! corpus member's IR has non-empty top-level arrays in practice, so this
//! hasn't bitten yet, but a chapter that legitimately emits an empty
//! `aggregates`/`policies`/etc. array will need this pinned before its
//! ir.json can byte-match — Stage 2's own differential harness
//! (spec/parser_parity_spec.rb) is what will actually surface it, not
//! guessed at here.

use std::fmt::Write as _;

/// A minimal, hand-rolled JSON value writer — no serde, matching this
/// crate's std-only dependency discipline (see Cargo.toml's own comment on
/// why). Real emit.rs, once ir::Bluebook is actually populated, will walk
/// the IR structs field-by-field in Ruby's own `to_h` key order rather
/// than going through a generic `JsonValue` — kept here only so this
/// module has something real and testable in Stage 1.
#[derive(Debug, Clone)]
pub enum JsonValue {
    Null,
    Bool(bool),
    Number(String),
    String(String),
    Array(Vec<JsonValue>),
    Object(Vec<(String, JsonValue)>),
}

pub fn write(value: &JsonValue) -> String {
    let mut out = String::new();
    write_value(&mut out, value, 0);
    out
}

fn indent(out: &mut String, depth: usize) {
    for _ in 0..depth {
        out.push_str("  ");
    }
}

fn write_value(out: &mut String, value: &JsonValue, depth: usize) {
    match value {
        JsonValue::Null => out.push_str("null"),
        JsonValue::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        JsonValue::Number(n) => out.push_str(n),
        JsonValue::String(s) => write_string(out, s),
        JsonValue::Array(items) => write_array(out, items, depth),
        JsonValue::Object(pairs) => write_object(out, pairs, depth),
    }
}

fn write_string(out: &mut String, text: &str) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn write_array(out: &mut String, items: &[JsonValue], depth: usize) {
    if items.is_empty() {
        // NOT the flagged hazard's answer — see this module's header. This
        // picks ONE spelling for Stage 1's own (currently unreachable)
        // tests; Stage 2 pins it for real against whatever json-gem
        // version CI actually resolves.
        out.push_str("[]");
        return;
    }
    out.push_str("[\n");
    for (idx, item) in items.iter().enumerate() {
        indent(out, depth + 1);
        write_value(out, item, depth + 1);
        if idx + 1 < items.len() {
            out.push(',');
        }
        out.push('\n');
    }
    indent(out, depth);
    out.push(']');
}

fn write_object(out: &mut String, pairs: &[(String, JsonValue)], depth: usize) {
    if pairs.is_empty() {
        out.push_str("{}");
        return;
    }
    out.push_str("{\n");
    for (idx, (key, val)) in pairs.iter().enumerate() {
        indent(out, depth + 1);
        write_string(out, key);
        out.push_str(": ");
        write_value(out, val, depth + 1);
        if idx + 1 < pairs.len() {
            out.push(',');
        }
        out.push('\n');
    }
    indent(out, depth);
    out.push('}');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_a_small_object() {
        let value = JsonValue::Object(vec![
            ("name".to_string(), JsonValue::String("Pizzas".to_string())),
            ("aggregates".to_string(), JsonValue::Array(vec![])),
        ]);
        assert_eq!(write(&value), "{\n  \"name\": \"Pizzas\",\n  \"aggregates\": []\n}");
    }
}
