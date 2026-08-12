//! A minimal, dependency-free JSON reader — deliberately NOT the typed
//! `rust/parser/src/ir.rs` structs. Those structs are shaped for the
//! PARSING direction (populated field-by-field while walking `.bluebook`
//! source, then serialized to match `to_h`'s JSON spelling) and use
//! Rust-native field names that diverge from the JSON keys themselves
//! (`type_name` vs the JSON key `"type"`, for one). `rust/project/*.rb`'s
//! own algorithms are written against the ACTUAL JSON-round-tripped Hash
//! (`ir[:name]`, `attr[:type]`, `vo[:closed_set]`, ...) — Stage 0c's own
//! reason for doing that round-trip in the first place was so the Ruby
//! generator never depends on live Ruby object/Symbol behavior, only on
//! plain JSON-shaped data. To port that algorithm faithfully and stay
//! directly comparable line-by-line against the Ruby source, this reads
//! ir.json the same way: a generic JSON value, indexed by string key,
//! exactly like `ir[:key]`.
//!
//! Only what codegen actually needs: parsing (never emits JSON — this
//! crate emits Rust source text, not JSON) and read accessors matching
//! the small vocabulary rust/project/*.rb actually uses (`Hash#[]`,
//! `Array#map`, `#to_s`, truthiness).

use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    // Int vs Float are kept SEPARATE, not one `Number(f64)` — Ruby's own
    // `JSON.generate`/`JSON.parse` round-trip distinguishes them by the
    // LITERAL SPELLING (a Float always prints with a decimal point, e.g.
    // `0.0`; an Integer never does), and `naming.rb#literal_rhs` (an
    // attribute's own `default:`) branches on the ORIGINAL Ruby type —
    // `Integer, Float then literal.to_s` looks like one case but Ruby's
    // `to_s` renders `0.0` for the Float and `0` for the Integer. A single
    // `f64` here would collapse that distinction (both parse to the same
    // numeric value) and silently mis-render a whole-number Float default
    // as a bare integer literal — a real, confirmed mismatch found live,
    // byte-diffing against Ruby's real output (`DailyFee.amount`, banking).
    Int(i64),
    Float(f64),
    String(String),
    Array(Vec<Json>),
    // Insertion-ordered pairs, not a HashMap — ir.json is never large
    // enough for linear lookup to matter, and preserving declaration
    // order matches what a real Ruby Hash (built by `to_h`) already
    // guarantees, the same ordering guarantee ir.rs's own header leans on.
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

    /// `ir[:key]` — Ruby's own Hash lookup. `None` for a missing key OR a
    /// present-but-`Json::Null` value: Ruby's `symbolize_names` JSON parse
    /// makes `nil` and "key absent" behave identically at every call site
    /// rust/project/*.rb actually has (`attr[:default]`, `attr[:pattern]`,
    /// `attr[:admits]` — every one of them is used as `if attr[:default]`/
    /// `attr[:pattern] && ...`, never distinguished from "key missing
    /// entirely"), so collapsing the two here matches every real caller.
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(pairs) => pairs.iter().find(|(k, v)| k == key && !matches!(v, Json::Null)).map(|(_, v)| v),
            _ => None,
        }
    }

    /// Raw lookup that DOES distinguish "absent" from "present as null" —
    /// needed by the one caller (`members` row lookup) that must tell a
    /// declared-but-blank field apart from one never declared at all.
    pub fn get_raw(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(pairs) => pairs.iter().find(|(k, _)| k == key).map(|(_, v)| v),
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

    pub fn as_bool(&self) -> bool {
        // Ruby truthiness on a JSON-round-tripped Hash value: everything
        // except `false`/`nil` is truthy, INCLUDING `0`/`""` (unlike most
        // other languages) — matches every `if attr[:optional]`/`if
        // vo[:closed_set]` call site, which never receives a `0`/`""` for
        // a boolean-shaped field in real ir.json anyway, but this is the
        // semantics-correct definition regardless.
        !matches!(self, Json::Bool(false) | Json::Null)
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Int(n) => Some(*n as f64),
            Json::Float(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Json::Int(n) => Some(*n),
            Json::Float(n) => Some(*n as i64),
            _ => None,
        }
    }

    /// `#to_s` on whatever's there — used where Ruby calls `.to_s` on a
    /// JSON scalar that's known to be a String already (`attr[:type].to_s`,
    /// `attr[:name].to_s`) but this stays defensive since a codegen bug
    /// reading the wrong key is better surfaced as an odd string than a
    /// panic.
    pub fn to_s(&self) -> String {
        match self {
            Json::Null => String::new(),
            Json::Bool(b) => b.to_string(),
            Json::Int(n) => n.to_string(),
            Json::Float(n) => format_number(*n),
            Json::String(s) => s.clone(),
            _ => String::new(),
        }
    }

    /// Iterate an array field, empty slice for anything else (mirrors
    /// Ruby's `Array(ir[:key])`/`(ir[:key] || [])` idiom used throughout
    /// rust/project/*.rb for list-shaped IR fields).
    pub fn each(&self) -> &[Json] {
        self.as_array().unwrap_or(&[])
    }
}

impl fmt::Display for Json {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_s())
    }
}

/// Ruby's `Float#to_s` — ALWAYS carries a decimal point (`0.0.to_s ==
/// "0.0"`), unlike Rust's own default `f64` `Display` (`format!("{}",
/// 0.0f64) == "0"`). Only reached for a genuine `Json::Float` now that
/// `Json::Int`/`Json::Float` are separate variants (see their own header)
/// — a whole-number JSON literal like `0` parses as `Json::Int` and never
/// reaches this function at all.
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
                    // Copy one UTF-8 char's worth of bytes at a time so
                    // multi-byte characters in string/description text
                    // (real corpus content includes them) survive intact.
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
        // A `.` or exponent in the LITERAL SPELLING means Ruby's own
        // `JSON.generate` wrote a Float (`0.0`); its absence means an
        // Integer (`0`) — see `Json::Int`/`Json::Float`'s own header on
        // why this distinction is load-bearing, not cosmetic.
        if text.contains('.') || text.contains('e') || text.contains('E') {
            text.parse::<f64>().map(Json::Float).map_err(|e| e.to_string())
        } else {
            text.parse::<i64>().map(Json::Int).map_err(|e| e.to_string())
        }
    }
}
