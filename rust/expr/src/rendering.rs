//! How an error message names a value, spelled as Ruby's `Rendering.describe` and
//! `Evaluator.class_of` do, so a refusal reads the same from every runtime.

use crate::expr::Value;
use crate::ruby_float;

/// Ruby's `String#inspect` for a UTF-8 string.
pub fn ruby_inspect(s: &str) -> String {
    use std::fmt::Write;
    let mut out = String::from("\"");
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            '\u{07}' => out.push_str("\\a"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0b}' => out.push_str("\\v"),
            '\u{0c}' => out.push_str("\\f"),
            '\u{1b}' => out.push_str("\\e"),
            '#' if matches!(chars.peek(), Some('{' | '$' | '@')) => out.push_str("\\#"),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => {
                let _ = write!(out, "\\u{:04X}", c as u32); // writing to a String cannot fail
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Ruby's `JSON.generate` for a value: what `describe` prints for a list or hash.
pub fn generate(v: &Value) -> String {
    match v {
        Value::Nil => "null".to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Int(i) => i.to_string(),
        Value::Float(f) => ruby_float::to_s(*f),
        Value::Str(s) => json_string(s),
        Value::List(_) => "[]".to_string(),
        Value::Array(items) => format!(
            "[{}]",
            items.iter().map(generate).collect::<Vec<_>>().join(",")
        ),
        Value::Object(fields) => format!(
            "{{{}}}",
            fields
                .iter()
                .map(|(key, field)| format!("{}:{}", json_string(key), generate(field)))
                .collect::<Vec<_>>()
                .join(",")
        ),
    }
}

/// A JSON string literal: quoted, with the escapes JSON requires.
fn json_string(s: &str) -> String {
    use std::fmt::Write;
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32); // writing to a String cannot fail
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Ruby's `Rendering.describe`: a value as an error message names it.
pub fn describe(v: &Value) -> String {
    match v {
        Value::Nil => "nil".to_string(),
        Value::Str(s) => ruby_inspect(s),
        other => generate(other),
    }
}

/// The Ruby class name an error message gives for a value; `nil` for nil, as `class_of` does.
pub const fn class_of(v: &Value) -> &'static str {
    match v {
        Value::Nil => "nil",
        Value::Int(_) => "Integer",
        Value::Float(_) => "Float",
        Value::Str(_) => "String",
        Value::Bool(true) => "TrueClass",
        Value::Bool(false) => "FalseClass",
        Value::List(_) | Value::Array(_) => "Array",
        // A value object's own class name is not in the data; Hash is the nearest honest answer.
        Value::Object(_) => "Hash",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strings_inspect_as_ruby_inspects_them() {
        assert_eq!(
            ruby_inspect("a\"b\\c\n\u{1}#{x}\u{7f}é"),
            "\"a\\\"b\\\\c\\n\\u0001\\#{x}\\u007Fé\""
        );
    }

    #[test]
    fn floats_print_as_ruby_prints_them() {
        for (f, text) in [
            (3.0, "3.0"),
            (0.5, "0.5"),
            (-0.0, "-0.0"),
            (100_000_000_000_000.0, "100000000000000.0"),
            (999_999_999_999_999.9, "999999999999999.9"),
            (1e15, "1.0e+15"),
            (1.5e15, "1.5e+15"),
            (1e20, "1.0e+20"),
            (0.0001, "0.0001"),
            (0.00001, "1.0e-05"),
            (1.5e-7, "1.5e-07"),
            (123_456_789.123_456_79, "123456789.12345679"),
        ] {
            assert_eq!(generate(&Value::Float(f)), text);
        }
    }
}
