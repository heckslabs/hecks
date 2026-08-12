//! A minimal, dependency-free, MUTABLE JSON value — the one genuine new
//! piece of infrastructure this crate needs beyond pure orchestration.
//! `rust/codegen/src/json.rs` (this crate's closest sibling) is
//! deliberately READ-ONLY (that file's own header: "this crate emits
//! Rust source text, not JSON") and `rust/parser/src/emit.rs` is a
//! WRITE-ONLY tree walker over `rust/parser/src/ir.rs`'s own typed
//! structs, not a generic value. Neither fits: this crate needs to
//! PARSE `hecks-parse`'s already-pretty `ir.json` text, MUTATE exactly
//! one boolean field in exactly the spots `mark_append_optional_fields!`
//! (`rust/project/mutations.rb`) would, and RE-EMIT the result matching
//! `JSON.pretty_generate` byte-for-byte — so a generic, editable tree
//! with its own reader AND writer earns its keep here in a way it
//! didn't in either sibling crate.
//!
//! THE NUMBER TYPE IS RAW TEXT, not `i64`/`f64` — deliberately, unlike
//! `rust/codegen/src/json.rs`'s `Int`/`Float` split (which exists there
//! because `naming.rb#literal_rhs` branches on Ruby's original numeric
//! TYPE). This crate never reads a number's value, only round-trips it
//! (the one numeric field in real `ir.json`, `ir_version`, is never
//! touched by the optional-marking pass) — storing the exact literal
//! substring the parser scanned and re-emitting it unchanged sidesteps
//! any float-formatting mismatch entirely, rather than risking one for
//! no benefit.
//!
//! THE WRITER is `rust/parser/src/emit.rs::write_value`/`write_array`/
//! `write_object`/`write_string`, copied algorithm-for-algorithm (not
//! shared via a library — the plan's own architecture decision keeps
//! `rust/parser`/`rust/codegen` untouched, sibling, subprocess-only
//! dependencies; the alternative, restructuring either into a library
//! crate this one could depend on, was explicitly rejected). Includes
//! the SAME pinned empty-array hazard `emit.rs`'s own header documents
//! (`JSON.pretty_generate({a: []})` renders `"{\n  \"a\": [\n\n  ]\n}"`
//! under the bundled json 2.7.2 gem this repo resolves — an extra,
//! unindented blank line, not simply `"[]"`) — unmodified fields in a
//! mutated `ir.json` still round-trip byte-exact only if this quirk is
//! reproduced exactly, and several real corpus arrays (`Order.entities`,
//! `Order.ports`, various `invariants`/`members`/`ensures`/`givens`/
//! `mutations`) are empty in practice, so this is exercised for real,
//! not theoretical.

use std::fmt::Write as _;

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    /// Raw literal text, exactly as scanned — see this module's own
    /// header on why this isn't `i64`/`f64`.
    Number(String),
    String(String),
    Array(Vec<Json>),
    /// Insertion-ordered pairs, not a `HashMap` — matches a real Ruby
    /// Hash's own iteration-order guarantee (`to_h`'s declaration
    /// order), which both `write_object` below and every real reader in
    /// this crate depend on for byte-exact re-emission.
    Object(Vec<(String, Json)>),
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

    /// `ir[:key]` — Ruby's own Hash lookup, collapsing "missing" and
    /// "present as null" the same way `rust/codegen/src/json.rs::get`
    /// already documents doing for the identical reason (every real
    /// caller in this crate treats the two the same).
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(pairs) => pairs.iter().find(|(k, v)| k == key && !matches!(v, Json::Null)).map(|(_, v)| v),
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

    /// Ruby truthiness on a JSON-round-tripped value — everything except
    /// `false`/`nil` is truthy. Matches every `if attr[:optional]` call
    /// site this crate ports (`rust/codegen/src/json.rs::as_bool`'s own
    /// identical reasoning).
    pub fn as_bool(&self) -> bool {
        !matches!(self, Json::Bool(false) | Json::Null)
    }

    /// Iterate an array field, empty slice for anything else — mirrors
    /// Ruby's `Array(ir[:key])` idiom.
    pub fn each(&self) -> &[Json] {
        self.as_array().unwrap_or(&[])
    }

    /// `field_attr[:optional] = true` — the one mutation this whole
    /// crate exists to perform. Finds the existing pair and overwrites
    /// its value (every real `IR::Attribute#to_h` always carries an
    /// `optional` key, per `attribute.rb`'s own unconditional
    /// `optional: optional` field, so the pair always already exists);
    /// falls back to appending a new pair only as a defensive measure,
    /// never reached against real corpus `ir.json`.
    pub fn set_bool(&mut self, key: &str, value: bool) {
        if let Json::Object(pairs) = self {
            if let Some((_, existing)) = pairs.iter_mut().find(|(k, _)| k == key) {
                *existing = Json::Bool(value);
                return;
            }
            pairs.push((key.to_string(), Json::Bool(value)));
        }
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
                    // One UTF-8 char's worth of bytes at a time, so
                    // multi-byte characters in real description text
                    // survive intact — same as rust/codegen/src/json.rs.
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

    /// Unlike `rust/codegen/src/json.rs::parse_number` (which classifies
    /// into `Int`/`Float`), this just captures the raw literal substring
    /// — see `Json::Number`'s own header on why.
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

/// Matches `JSON.pretty_generate` byte-for-byte for the bundled `json`
/// gem this repo resolves — the identical algorithm as
/// `rust/parser/src/emit.rs::write`, copied rather than shared (this
/// crate's own header on why). Verified against the same real corpus
/// (pizzas, banking) both `spec/parser_parity_spec.rb` and this crate's
/// own `spec/hecks_build_pipeline_spec.rb` already hold to byte-exact.
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
        // THE PINNED HAZARD — see this module's own header.
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
    // No special case for an empty object — see emit.rs's own header:
    // the ordinary loop already produces the right bytes when it simply
    // runs zero times.
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
    fn round_trips_a_small_object_with_an_empty_array() {
        let text = "{\n  \"name\": \"Pizzas\",\n  \"aggregates\": [\n\n  ]\n}";
        let value = Json::parse(text).expect("parses");
        assert_eq!(write(&value), text);
    }

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
}
