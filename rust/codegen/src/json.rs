//! A minimal, dependency-free, mutable JSON value indexed by string key, like the Ruby `ir[:key]`
//! Hash, with a reader and a pretty writer. The writer matches `JSON.pretty_generate`
//! byte-for-byte, including its empty-array quirk.

use std::fmt;
use std::fmt::Write as _;

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    /// Raw literal text as scanned, so numbers round-trip unchanged; `number` reads it as Ruby wrote it.
    Number(String),
    String(String),
    Array(Vec<Json>),
    /// Insertion-ordered pairs, matching the declaration order of the Ruby Hash; byte-exact
    /// re-emission depends on key order.
    Object(Vec<(String, Json)>),
}

/// A `Json::Number` as Ruby wrote it: a `.` or an exponent means a Float, anything else an
/// Integer. Kept apart: a whole-number Float default (`0.0`) must not render as `0`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Number {
    Int(i64),
    Float(f64),
}

impl Json {
    pub fn parse(text: &str) -> Result<Json, String> {
        let mut p = Parser { bytes: text.as_bytes(), pos: 0 };
        p.skip_ws();
        let value = p.parse_value()?;
        p.skip_ws();
        if p.pos != p.bytes.len() {
            return Err(format!("trailing content at byte {}", p.pos));
        }
        Ok(value)
    }

    /// `ir[:key]`: `None` for a missing key or a `Json::Null` value.
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(pairs) => pairs.iter().find(|(k, v)| k == key && !matches!(v, Json::Null)).map(|(_, v)| v),
            _ => None,
        }
    }

    /// Like `get`, but distinguishes an absent key from one present as null.
    pub fn get_raw(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(pairs) => pairs.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn get_mut(&mut self, key: &str) -> Option<&mut Json> {
        match self {
            Json::Object(pairs) => pairs.iter_mut().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::String(s) => Some(s.as_str()),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(items) => Some(items.as_slice()),
            _ => None,
        }
    }

    pub fn as_array_mut(&mut self) -> Option<&mut Vec<Json>> {
        match self {
            Json::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_object(&self) -> Option<&[(String, Json)]> {
        match self {
            Json::Object(pairs) => Some(pairs.as_slice()),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> bool {
        // Ruby truthiness: only `false` and `nil` are falsy, so `0` and `""` are truthy.
        !matches!(self, Json::Bool(false) | Json::Null)
    }

    /// The number as Ruby wrote it, or `None` for any other value. An integer too large for `i64`
    /// reads as a Float.
    pub fn number(&self) -> Option<Number> {
        let Json::Number(text) = self else { return None };
        if text.contains(|c| matches!(c, '.' | 'e' | 'E')) {
            return text.parse::<f64>().ok().map(Number::Float);
        }
        match text.parse::<i64>() {
            Ok(n) => Some(Number::Int(n)),
            Err(_) => text.parse::<f64>().ok().map(Number::Float),
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        self.number().map(|n| match n {
            Number::Int(n) => n as f64,
            Number::Float(n) => n,
        })
    }

    pub fn as_i64(&self) -> Option<i64> {
        self.number().map(|n| match n {
            Number::Int(n) => n,
            Number::Float(n) => n as i64,
        })
    }

    /// `#to_s` on a scalar; non-scalars render as the empty string rather than panicking.
    pub fn to_s(&self) -> String {
        match self {
            Json::Null => String::new(),
            Json::Bool(b) => b.to_string(),
            Json::Number(text) => match self.number() {
                Some(Number::Int(n)) => n.to_string(),
                Some(Number::Float(n)) => format_number(n),
                None => text.clone(),
            },
            Json::String(s) => s.clone(),
            _ => String::new(),
        }
    }

    /// Array items, or an empty slice for any other value (Ruby's `Array(ir[:key])`).
    pub fn each(&self) -> &[Json] {
        self.as_array().unwrap_or(&[])
    }

    /// Sets `key` to `value`, overwriting in place or else appending last.
    pub fn set(&mut self, key: &str, value: Json) {
        if let Json::Object(pairs) = self {
            if let Some((_, existing)) = pairs.iter_mut().find(|(k, _)| k == key) {
                *existing = value;
                return;
            }
            pairs.push((key.to_string(), value));
        }
    }

    pub fn set_bool(&mut self, key: &str, value: bool) {
        self.set(key, Json::Bool(value));
    }
}

impl fmt::Display for Json {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_s())
    }
}

/// Ruby's `Float#to_s`: always carries a decimal point (`0.0`), unlike Rust's `{}`.
fn format_number(n: f64) -> String {
    let text = format!("{n}");
    if text.contains('.') || text.contains('e') || text.contains('E') {
        text
    } else {
        format!("{text}.0")
    }
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn skip_ws(&mut self) {
        while let Some(b) = self.peek() {
            if b == b' ' || b == b'\t' || b == b'\n' || b == b'\r' {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn expect(&mut self, b: u8) -> Result<(), String> {
        if self.peek() == Some(b) {
            self.pos += 1;
            Ok(())
        } else {
            Err(format!("expected {:?} at byte {}, found {:?}", b as char, self.pos, self.peek().map(|c| c as char)))
        }
    }

    fn parse_value(&mut self) -> Result<Json, String> {
        self.skip_ws();
        match self.peek() {
            Some(b'{') => self.parse_object(),
            Some(b'[') => self.parse_array(),
            Some(b'"') => Ok(Json::String(self.parse_string()?)),
            Some(b't') => {
                self.expect_literal("true")?;
                Ok(Json::Bool(true))
            }
            Some(b'f') => {
                self.expect_literal("false")?;
                Ok(Json::Bool(false))
            }
            Some(b'n') => {
                self.expect_literal("null")?;
                Ok(Json::Null)
            }
            Some(c) if c == b'-' || c.is_ascii_digit() => self.parse_number(),
            other => Err(format!("unexpected byte {:?} at {}", other.map(|c| c as char), self.pos)),
        }
    }

    fn expect_literal(&mut self, lit: &str) -> Result<(), String> {
        let end = self.pos + lit.len();
        if end <= self.bytes.len() && &self.bytes[self.pos..end] == lit.as_bytes() {
            self.pos = end;
            Ok(())
        } else {
            Err(format!("expected literal {lit:?} at byte {}", self.pos))
        }
    }

    fn parse_object(&mut self) -> Result<Json, String> {
        self.expect(b'{')?;
        let mut pairs = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Json::Object(pairs));
        }
        loop {
            self.skip_ws();
            let key = self.parse_string()?;
            self.skip_ws();
            self.expect(b':')?;
            let value = self.parse_value()?;
            pairs.push((key, value));
            self.skip_ws();
            match self.peek() {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b'}') => {
                    self.pos += 1;
                    break;
                }
                other => return Err(format!("expected ',' or '}}' at byte {}, found {:?}", self.pos, other.map(|c| c as char))),
            }
        }
        Ok(Json::Object(pairs))
    }

    fn parse_array(&mut self) -> Result<Json, String> {
        self.expect(b'[')?;
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Json::Array(items));
        }
        loop {
            let value = self.parse_value()?;
            items.push(value);
            self.skip_ws();
            match self.peek() {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b']') => {
                    self.pos += 1;
                    break;
                }
                other => return Err(format!("expected ',' or ']' at byte {}, found {:?}", self.pos, other.map(|c| c as char))),
            }
        }
        Ok(Json::Array(items))
    }

    fn parse_string(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        let mut out = String::new();
        loop {
            match self.peek() {
                None => return Err("unterminated string".to_string()),
                Some(b'"') => {
                    self.pos += 1;
                    break;
                }
                Some(b'\\') => {
                    self.pos += 1;
                    match self.peek() {
                        Some(b'"') => {
                            out.push('"');
                            self.pos += 1;
                        }
                        Some(b'\\') => {
                            out.push('\\');
                            self.pos += 1;
                        }
                        Some(b'/') => {
                            out.push('/');
                            self.pos += 1;
                        }
                        Some(b'n') => {
                            out.push('\n');
                            self.pos += 1;
                        }
                        Some(b't') => {
                            out.push('\t');
                            self.pos += 1;
                        }
                        Some(b'r') => {
                            out.push('\r');
                            self.pos += 1;
                        }
                        Some(b'b') => {
                            out.push('\u{8}');
                            self.pos += 1;
                        }
                        Some(b'f') => {
                            out.push('\u{c}');
                            self.pos += 1;
                        }
                        Some(b'u') => {
                            self.pos += 1;
                            let hex = std::str::from_utf8(&self.bytes[self.pos..self.pos + 4]).map_err(|e| e.to_string())?;
                            let code = u32::from_str_radix(hex, 16).map_err(|e| e.to_string())?;
                            self.pos += 4;
                            if let Some(c) = char::from_u32(code) {
                                out.push(c);
                            }
                        }
                        other => return Err(format!("bad escape {:?}", other.map(|c| c as char))),
                    }
                }
                Some(_) => {
                    // One UTF-8 char at a time so multi-byte text survives intact.
                    let start = self.pos;
                    let rest = std::str::from_utf8(&self.bytes[start..]).map_err(|e| e.to_string())?;
                    let ch = rest.chars().next().ok_or("empty remainder")?;
                    out.push(ch);
                    self.pos += ch.len_utf8();
                }
            }
        }
        Ok(out)
    }

    // Keeps the raw literal text, so numbers round-trip unchanged.
    fn parse_number(&mut self) -> Result<Json, String> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
            self.pos += 1;
        }
        if self.peek() == Some(b'.') {
            self.pos += 1;
            while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
                self.pos += 1;
            }
        }
        if matches!(self.peek(), Some(b'e') | Some(b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+') | Some(b'-')) {
                self.pos += 1;
            }
            while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
                self.pos += 1;
            }
        }
        let text = std::str::from_utf8(&self.bytes[start..self.pos]).map_err(|e| e.to_string())?;
        Ok(Json::Number(text.to_string()))
    }
}

/// Renders `value` exactly as `JSON.pretty_generate` does for the pinned json gem.
pub fn write(value: &Json) -> String {
    let mut out = String::new();
    write_value(&mut out, value, 0);
    out
}

fn indent(out: &mut String, depth: usize) {
    for _ in 0..depth {
        out.push_str("  ");
    }
}

fn write_value(out: &mut String, value: &Json, depth: usize) {
    match value {
        Json::Null => out.push_str("null"),
        Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Json::Number(n) => out.push_str(n),
        Json::String(s) => write_string(out, s),
        Json::Array(items) => write_array(out, items, depth),
        Json::Object(pairs) => write_object(out, pairs, depth),
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

fn write_array(out: &mut String, items: &[Json], depth: usize) {
    if items.is_empty() {
        // Empty arrays render with a blank line, matching the pinned json gem.
        out.push_str("[\n\n");
        indent(out, depth);
        out.push(']');
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

fn write_object(out: &mut String, pairs: &[(String, Json)], depth: usize) {
    // An empty object needs no special case: the loop runs zero times.
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
    fn round_trips_an_empty_object() {
        let text = "{\n}";
        let value = Json::parse(text).expect("parses");
        assert_eq!(write(&value), text);
    }

    #[test]
    fn set_bool_overwrites_an_existing_key() {
        let mut value = Json::parse("{\n  \"optional\": false\n}").expect("parses");
        value.set_bool("optional", true);
        assert_eq!(write(&value), "{\n  \"optional\": true\n}");
    }

    // A whole-number Float default must keep its `.0`, in the text and when rendered.
    #[test]
    fn keeps_a_float_apart_from_an_integer() {
        let value = Json::parse("[0.0, 0, 1e3, -7, 12345678901234567890]").expect("parses");
        let numbers: Vec<Option<Number>> = value.each().iter().map(Json::number).collect();

        assert_eq!(numbers[0], Some(Number::Float(0.0)));
        assert_eq!(numbers[1], Some(Number::Int(0)));
        assert_eq!(numbers[2], Some(Number::Float(1000.0)));
        assert_eq!(numbers[3], Some(Number::Int(-7)));
        assert!(matches!(numbers[4], Some(Number::Float(_))), "an integer past i64 reads as a Float");
        assert_eq!(value.each()[0].to_s(), "0.0");
        assert_eq!(value.each()[1].to_s(), "0");
    }

    #[test]
    fn writes_numbers_as_scanned() {
        let text = "[\n  0.0,\n  1e3,\n  -7\n]";
        assert_eq!(write(&Json::parse(text).expect("parses")), text);
    }

    #[test]
    fn reads_as_i64_and_f64_across_both_kinds() {
        let value = Json::parse("[3, 2.5]").expect("parses");
        assert_eq!(value.each()[0].as_f64(), Some(3.0));
        assert_eq!(value.each()[1].as_i64(), Some(2));
        assert_eq!(Json::String("3".to_string()).as_i64(), None);
    }

    #[test]
    fn get_treats_null_as_missing_and_get_raw_does_not() {
        let value = Json::parse("{\"a\": null}").expect("parses");
        assert!(value.get("a").is_none());
        assert_eq!(value.get_raw("a"), Some(&Json::Null));
    }
}
