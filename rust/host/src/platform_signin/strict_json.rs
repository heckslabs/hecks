//! A JSON reader that accepts only what two parsers could not disagree about.
//!
//! The standard parsers keep the last of a repeated key and accept deep nesting. A token whose
//! header or claims repeat a key could be read one way here and another way by the issuer, so this
//! reader refuses it. It also keeps numbers apart from each other (an integer is not a float)
//! because
//! the time claims must be integers.

use std::collections::HashMap;

/// A parsed JSON value, reduced to the shapes a token check needs to tell apart.
#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    /// An integer; a digit string beyond the `i128` range saturates, which keeps every comparison
    /// against a time window the same as an unbounded integer would give.
    Int(i128),
    /// Any number that is not an integer literal (a fraction or an exponent).
    Number,
    Str(String),
    Array(Vec<Json>),
    Object(JsonObject),
}

/// A JSON object with unique keys.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct JsonObject(HashMap<String, Json>);

impl JsonObject {
    /// Finds a member by name.
    pub fn get(&self, name: &str) -> Option<&Json> {
        self.0.get(name)
    }

    /// Finds a member that is a string.
    pub fn get_str(&self, name: &str) -> Option<&str> {
        match self.get(name) {
            Some(Json::Str(text)) => Some(text),
            _ => None,
        }
    }

    /// Tells whether the member exists and is not JSON `null`.
    pub fn is_present(&self, name: &str) -> bool {
        !matches!(self.get(name), None | Some(Json::Null))
    }

    /// Lists the member names, in no particular order.
    pub fn keys(&self) -> impl Iterator<Item = &String> {
        self.0.keys()
    }
}

/// The deepest nesting accepted, counting the outer object as depth 1.
pub const MAX_DEPTH: usize = 8;

/// Parses `bytes` as one JSON object and nothing else.
///
/// Returns `None` for invalid UTF-8, invalid JSON, trailing text, a value that is not an object,
/// an object that repeats a key at any depth, and nesting deeper than [`MAX_DEPTH`].
pub fn parse_object(bytes: &[u8]) -> Option<JsonObject> {
    let text = std::str::from_utf8(bytes).ok()?;
    let mut parser = Parser {
        bytes: text.as_bytes(),
        at: 0,
    };
    parser.skip_whitespace();
    let object = parser.object(0)?;
    parser.skip_whitespace();
    (parser.at == parser.bytes.len()).then_some(object)
}

/// A recursive-descent reader over validated UTF-8; every method returns `None` at the first fault.
struct Parser<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Parser<'_> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    fn skip_whitespace(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.at += 1;
        }
    }

    fn expect(&mut self, byte: u8) -> Option<()> {
        (self.peek() == Some(byte)).then(|| self.at += 1)
    }

    fn value(&mut self, depth: usize) -> Option<Json> {
        match self.peek()? {
            b'{' => self.object(depth).map(Json::Object),
            b'[' => self.array(depth),
            b'"' => self.string().map(Json::Str),
            b't' => self.literal(b"true", Json::Bool(true)),
            b'f' => self.literal(b"false", Json::Bool(false)),
            b'n' => self.literal(b"null", Json::Null),
            b'-' | b'0'..=b'9' => self.number(),
            _ => None,
        }
    }

    fn literal(&mut self, word: &[u8], value: Json) -> Option<Json> {
        let end = self.at + word.len();
        (self.bytes.get(self.at..end)? == word).then(|| {
            self.at = end;
            value
        })
    }

    fn object(&mut self, depth: usize) -> Option<JsonObject> {
        let depth = depth + 1;
        if depth > MAX_DEPTH {
            return None;
        }
        self.expect(b'{')?;
        let mut members = HashMap::new();
        self.skip_whitespace();
        if self.peek() == Some(b'}') {
            self.at += 1;
            return Some(JsonObject(members));
        }
        loop {
            self.skip_whitespace();
            let key = self.string()?;
            self.skip_whitespace();
            self.expect(b':')?;
            self.skip_whitespace();
            let value = self.value(depth)?;
            if members.insert(key, value).is_some() {
                return None;
            }
            self.skip_whitespace();
            match self.peek()? {
                b',' => self.at += 1,
                b'}' => {
                    self.at += 1;
                    return Some(JsonObject(members));
                }
                _ => return None,
            }
        }
    }

    fn array(&mut self, depth: usize) -> Option<Json> {
        let depth = depth + 1;
        if depth > MAX_DEPTH {
            return None;
        }
        self.expect(b'[')?;
        let mut items = Vec::new();
        self.skip_whitespace();
        if self.peek() == Some(b']') {
            self.at += 1;
            return Some(Json::Array(items));
        }
        loop {
            self.skip_whitespace();
            items.push(self.value(depth)?);
            self.skip_whitespace();
            match self.peek()? {
                b',' => self.at += 1,
                b']' => {
                    self.at += 1;
                    return Some(Json::Array(items));
                }
                _ => return None,
            }
        }
    }

    fn string(&mut self) -> Option<String> {
        self.expect(b'"')?;
        let mut out: Vec<u8> = Vec::new();
        loop {
            let byte = self.peek()?;
            self.at += 1;
            match byte {
                b'"' => return String::from_utf8(out).ok(),
                b'\\' => self.escape(&mut out)?,
                0x00..=0x1f => return None,
                other => out.push(other),
            }
        }
    }

    fn escape(&mut self, out: &mut Vec<u8>) -> Option<()> {
        let byte = self.peek()?;
        self.at += 1;
        let simple = match byte {
            b'"' => b'"',
            b'\\' => b'\\',
            b'/' => b'/',
            b'b' => 0x08,
            b'f' => 0x0c,
            b'n' => b'\n',
            b'r' => b'\r',
            b't' => b'\t',
            b'u' => return self.unicode_escape(out),
            _ => return None,
        };
        out.push(simple);
        Some(())
    }

    fn unicode_escape(&mut self, out: &mut Vec<u8>) -> Option<()> {
        let first = self.hex4()?;
        let code = match first {
            0xD800..=0xDBFF => {
                self.expect(b'\\')?;
                self.expect(b'u')?;
                let second = self.hex4()?;
                if !(0xDC00..=0xDFFF).contains(&second) {
                    return None;
                }
                0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            }
            0xDC00..=0xDFFF => return None,
            plain => plain,
        };
        let mut buffer = [0u8; 4];
        out.extend_from_slice(char::from_u32(code)?.encode_utf8(&mut buffer).as_bytes());
        Some(())
    }

    fn hex4(&mut self) -> Option<u32> {
        let digits = self.bytes.get(self.at..self.at + 4)?;
        let text = std::str::from_utf8(digits).ok()?;
        if !text.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        self.at += 4;
        u32::from_str_radix(text, 16).ok()
    }

    fn digits(&mut self) -> Option<usize> {
        let start = self.at;
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.at += 1;
        }
        (self.at > start).then_some(self.at - start)
    }

    fn number(&mut self) -> Option<Json> {
        let negative = self.peek() == Some(b'-');
        if negative {
            self.at += 1;
        }
        let integer_start = self.at;
        if self.peek() == Some(b'0') {
            self.at += 1;
        } else {
            self.digits()?;
        }
        let integer_end = self.at;
        let mut integral = true;
        if self.peek() == Some(b'.') {
            self.at += 1;
            self.digits()?;
            integral = false;
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.at += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.at += 1;
            }
            self.digits()?;
            integral = false;
        }
        if !integral {
            return Some(Json::Number);
        }
        let text = std::str::from_utf8(&self.bytes[integer_start..integer_end]).ok()?;
        Some(Json::Int(integer_from(text, negative)))
    }
}

/// Reads an integer literal's digits, saturating at the `i128` limits instead of failing.
fn integer_from(digits: &str, negative: bool) -> i128 {
    match digits.parse::<i128>() {
        Ok(value) if negative => -value,
        Ok(value) => value,
        Err(_) if negative => i128::MIN,
        Err(_) => i128::MAX,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> Option<JsonObject> {
        parse_object(text.as_bytes())
    }

    #[test]
    fn an_object_parses_and_its_members_are_readable() {
        let object = parse(r#"{"a":"x","b":7,"c":true,"d":null}"#).expect("object");
        assert_eq!(object.get_str("a"), Some("x"));
        assert_eq!(object.get("b"), Some(&Json::Int(7)));
        assert_eq!(object.get("c"), Some(&Json::Bool(true)));
        assert!(!object.is_present("d"));
        assert!(!object.is_present("missing"));
    }

    #[test]
    fn a_repeated_key_is_refused_at_the_top_and_when_nested() {
        assert!(parse(r#"{"a":1,"a":2}"#).is_none());
        assert!(parse(r#"{"a":{"b":1,"b":1}}"#).is_none());
        assert!(parse(r#"{"a":[{"b":1,"b":1}]}"#).is_none());
    }

    #[test]
    fn only_an_object_is_accepted() {
        for text in [
            "[]", "\"s\"", "1", "true", "null", "", "   ", "{", "{}x", "{} {}",
        ] {
            assert!(parse(text).is_none(), "{text:?} must be refused");
        }
        assert!(parse("{}").is_some());
        assert!(parse(" {} ").is_some());
    }

    #[test]
    fn invalid_utf8_is_refused() {
        assert!(parse_object(b"{\"a\":\"\xff\"}").is_none());
    }

    #[test]
    fn integers_and_other_numbers_are_told_apart() {
        let object = parse(r#"{"i":-5,"f":1.5,"e":1e2,"z":1.0,"big":99999999999999999999999999999999999999999999}"#).expect("object");
        assert_eq!(object.get("i"), Some(&Json::Int(-5)));
        assert_eq!(object.get("f"), Some(&Json::Number));
        assert_eq!(object.get("e"), Some(&Json::Number));
        assert_eq!(object.get("z"), Some(&Json::Number));
        assert_eq!(object.get("big"), Some(&Json::Int(i128::MAX)));
    }

    #[test]
    fn nesting_is_capped_at_eight_levels() {
        let ok = format!(r#"{{"a":{}{}}}"#, "[".repeat(7), "]".repeat(7));
        assert!(parse(&ok).is_some(), "depth 8 is allowed");
        let deep = format!(r#"{{"a":{}{}}}"#, "[".repeat(8), "]".repeat(8));
        assert!(parse(&deep).is_none(), "depth 9 is refused");
    }
}
