//! A small JSON reader and writer for the harness's wire: one JSON value per line.
//!
//! Objects keep their keys in the order they were read or built, so a line the harness writes
//! reads the same way every time and a recorded line can be compared byte for byte.

use std::fmt::Write as _;

/// One JSON value.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    /// `null`.
    Null,
    /// `true` or `false`.
    Bool(bool),
    /// A number, held as JSON holds it: a double.
    Number(f64),
    /// A string.
    String(String),
    /// An array.
    Array(Vec<Self>),
    /// An object, its keys in order.
    Object(Vec<(String, Self)>),
}

impl Value {
    /// Builds an object from key and value pairs, in the order given.
    pub fn object<K: Into<String>>(pairs: Vec<(K, Self)>) -> Self {
        Self::Object(
            pairs
                .into_iter()
                .map(|(key, value)| (key.into(), value))
                .collect(),
        )
    }

    /// A string value.
    pub fn text(value: impl Into<String>) -> Self {
        Self::String(value.into())
    }

    /// The value under `key`, when this is an object that holds it.
    pub fn get(&self, key: &str) -> Option<&Self> {
        match self {
            Self::Object(pairs) => pairs
                .iter()
                .find(|(name, _)| name == key)
                .map(|(_, value)| value),
            _ => None,
        }
    }

    /// The string under `key`, when there is one.
    pub fn str_at(&self, key: &str) -> Option<&str> {
        self.get(key).and_then(Self::as_str)
    }

    /// This value as a string, when it is one.
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(text) => Some(text),
            _ => None,
        }
    }

    /// This value as a bool, when it is one.
    pub const fn as_bool(&self) -> Option<bool> {
        match self {
            Self::Bool(flag) => Some(*flag),
            _ => None,
        }
    }

    /// This value as a number, when it is one.
    pub const fn as_f64(&self) -> Option<f64> {
        match self {
            Self::Number(number) => Some(*number),
            _ => None,
        }
    }

    /// The items, when this is an array.
    pub fn as_array(&self) -> Option<&[Self]> {
        match self {
            Self::Array(items) => Some(items),
            _ => None,
        }
    }

    /// Writes this value as compact JSON on one line.
    pub fn to_json(&self) -> String {
        let mut out = String::new();
        write_value(self, &mut out);
        out
    }
}

/// Reads one JSON value from `text`, refusing anything after it but whitespace.
///
/// # Errors
///
/// Returns a message naming the byte offset where the text stops being JSON.
pub fn parse(text: &str) -> Result<Value, String> {
    let mut reader = Reader {
        bytes: text.as_bytes(),
        at: 0,
    };
    let value = reader.value()?;
    reader.skip_space();
    if reader.at == reader.bytes.len() {
        Ok(value)
    } else {
        Err(format!(
            "unexpected text after the JSON value at byte {}",
            reader.at
        ))
    }
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    fn skip_space(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.at += 1;
        }
    }

    fn fail<T>(&self, what: &str) -> Result<T, String> {
        Err(format!("{what} at byte {}", self.at))
    }

    fn value(&mut self) -> Result<Value, String> {
        self.skip_space();
        match self.peek() {
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => self.string().map(Value::String),
            Some(b't') => self.word("true", Value::Bool(true)),
            Some(b'f') => self.word("false", Value::Bool(false)),
            Some(b'n') => self.word("null", Value::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => self.fail("expected a JSON value"),
            None => self.fail("the text ended before a JSON value"),
        }
    }

    fn word(&mut self, word: &str, value: Value) -> Result<Value, String> {
        if self.bytes[self.at..].starts_with(word.as_bytes()) {
            self.at += word.len();
            Ok(value)
        } else {
            self.fail("expected a JSON value")
        }
    }

    fn number(&mut self) -> Result<Value, String> {
        let start = self.at;
        while matches!(
            self.peek(),
            Some(b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')
        ) {
            self.at += 1;
        }
        let digits = std::str::from_utf8(&self.bytes[start..self.at]).unwrap_or_default();
        digits
            .parse::<f64>()
            .map(Value::Number)
            .or_else(|_| self.fail("expected a number"))
    }

    fn array(&mut self) -> Result<Value, String> {
        self.at += 1;
        let mut items = Vec::new();
        self.skip_space();
        if self.peek() == Some(b']') {
            self.at += 1;
            return Ok(Value::Array(items));
        }
        loop {
            items.push(self.value()?);
            self.skip_space();
            match self.peek() {
                Some(b',') => self.at += 1,
                Some(b']') => {
                    self.at += 1;
                    return Ok(Value::Array(items));
                }
                _ => return self.fail("expected , or ] in an array"),
            }
        }
    }

    fn object(&mut self) -> Result<Value, String> {
        self.at += 1;
        let mut pairs = Vec::new();
        self.skip_space();
        if self.peek() == Some(b'}') {
            self.at += 1;
            return Ok(Value::Object(pairs));
        }
        loop {
            self.skip_space();
            if self.peek() != Some(b'"') {
                return self.fail("expected a key in an object");
            }
            let key = self.string()?;
            self.skip_space();
            if self.peek() != Some(b':') {
                return self.fail("expected : after a key");
            }
            self.at += 1;
            pairs.push((key, self.value()?));
            self.skip_space();
            match self.peek() {
                Some(b',') => self.at += 1,
                Some(b'}') => {
                    self.at += 1;
                    return Ok(Value::Object(pairs));
                }
                _ => return self.fail("expected , or } in an object"),
            }
        }
    }

    fn string(&mut self) -> Result<String, String> {
        self.at += 1;
        let mut out = String::new();
        loop {
            let start = self.at;
            while !matches!(self.peek(), Some(b'"' | b'\\') | None) {
                self.at += 1;
            }
            out.push_str(
                std::str::from_utf8(&self.bytes[start..self.at])
                    .map_err(|_| "a string is not UTF-8")?,
            );
            match self.peek() {
                Some(b'"') => {
                    self.at += 1;
                    return Ok(out);
                }
                Some(b'\\') => self.escape(&mut out)?,
                _ => return self.fail("the text ended inside a string"),
            }
        }
    }

    fn escape(&mut self, out: &mut String) -> Result<(), String> {
        self.at += 1;
        let Some(code) = self.peek() else {
            return self.fail("the text ended inside an escape");
        };
        self.at += 1;
        match code {
            b'"' => out.push('"'),
            b'\\' => out.push('\\'),
            b'/' => out.push('/'),
            b'b' => out.push('\u{8}'),
            b'f' => out.push('\u{c}'),
            b'n' => out.push('\n'),
            b'r' => out.push('\r'),
            b't' => out.push('\t'),
            b'u' => out.push(self.unicode()?),
            _ => return self.fail("an unknown escape"),
        }
        Ok(())
    }

    fn unicode(&mut self) -> Result<char, String> {
        let high = self.hex4()?;
        if !(0xD800..0xDC00).contains(&high) {
            return char::from_u32(high).map_or_else(|| self.fail("an invalid \\u escape"), Ok);
        }
        if !self.bytes[self.at..].starts_with(b"\\u") {
            return self.fail("a lone surrogate in a \\u escape");
        }
        self.at += 2;
        let low = self.hex4()?;
        let joined = 0x10000 + ((high - 0xD800) << 10) + (low.wrapping_sub(0xDC00) & 0x3FF);
        char::from_u32(joined).map_or_else(|| self.fail("an invalid surrogate pair"), Ok)
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let digits = self
            .bytes
            .get(self.at..self.at + 4)
            .and_then(|slice| std::str::from_utf8(slice).ok());
        let Some(parsed) = digits.and_then(|text| u32::from_str_radix(text, 16).ok()) else {
            return self.fail("expected four hex digits");
        };
        self.at += 4;
        Ok(parsed)
    }
}

fn write_value(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Number(number) => write_number(*number, out),
        Value::String(text) => write_string(text, out),
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_value(item, out);
            }
            out.push(']');
        }
        Value::Object(pairs) => {
            out.push('{');
            for (index, (key, item)) in pairs.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_string(key, out);
                out.push(':');
                write_value(item, out);
            }
            out.push('}');
        }
    }
}

fn write_number(number: f64, out: &mut String) {
    if !number.is_finite() {
        out.push_str("null");
    } else if number.fract() == 0.0 && number.abs() < 9.0e15 {
        let _ = write!(out, "{}", number as i64);
    } else {
        let _ = write!(out, "{number}");
    }
}

fn write_string(text: &str, out: &mut String) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if (ch as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", ch as u32);
            }
            ch => out.push(ch),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_and_writes_a_nested_line_unchanged() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"hi \"you\""}]},"n":3,"ok":true,"x":null}"#;
        assert_eq!(parse(line).unwrap().to_json(), line);
    }

    #[test]
    fn keeps_key_order() {
        let value = Value::object(vec![("b", Value::Null), ("a", Value::Bool(false))]);
        assert_eq!(value.to_json(), r#"{"b":null,"a":false}"#);
    }

    #[test]
    fn reads_escapes_and_surrogate_pairs() {
        let value = parse(r#""tab\tline\nsnow ☃ 😀""#).unwrap();
        assert_eq!(value.as_str(), Some("tab\tline\nsnow \u{2603} \u{1f600}"));
    }

    #[test]
    fn writes_control_characters_escaped() {
        assert_eq!(Value::text("a\u{1}b").to_json(), r#""a\u0001b""#);
    }

    #[test]
    fn writes_whole_numbers_without_a_fraction() {
        assert_eq!(
            parse("[12, -3.5, 1e3]").unwrap().to_json(),
            "[12,-3.5,1000]"
        );
    }

    #[test]
    fn refuses_trailing_text() {
        assert!(parse("{} x").unwrap_err().contains("byte 3"));
    }

    #[test]
    fn refuses_an_unclosed_string() {
        assert!(parse(r#"{"a":"b"#).is_err());
    }

    #[test]
    fn finds_values_by_key() {
        let value = parse(r#"{"type":"result","is_error":false,"duration_ms":40}"#).unwrap();
        assert_eq!(value.str_at("type"), Some("result"));
        assert_eq!(value.get("is_error").and_then(Value::as_bool), Some(false));
        assert_eq!(value.get("duration_ms").and_then(Value::as_f64), Some(40.0));
    }
}
