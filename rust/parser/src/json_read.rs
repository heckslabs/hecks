//! A strict JSON reader, into the same [`JsonValue`] the emitter writes.
//!
//! The parser crate has no dependencies (see `Cargo.toml`), and the one JSON it reads is the
//! asking a declared adapter answers, which the runtime writes. Numbers keep their text, so an
//! integer reads back exactly as it was written.

use crate::emit::JsonValue;

/// Reads one JSON document, refusing trailing text.
pub fn read(text: &str) -> Result<JsonValue, String> {
    let mut reader = Reader {
        chars: text.chars().collect(),
        at: 0,
    };
    let value = reader.value()?;
    reader.blank();
    if reader.at < reader.chars.len() {
        return Err(format!(
            "unexpected text after JSON at character {}",
            reader.at
        ));
    }
    Ok(value)
}

struct Reader {
    chars: Vec<char>,
    at: usize,
}

impl Reader {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.at).copied()
    }

    fn blank(&mut self) {
        while self.peek().is_some_and(char::is_whitespace) {
            self.at += 1;
        }
    }

    fn expect(&mut self, wanted: char) -> Result<(), String> {
        self.blank();
        if self.peek() == Some(wanted) {
            self.at += 1;
            Ok(())
        } else {
            Err(format!("expected '{wanted}' at character {}", self.at))
        }
    }

    fn word(&mut self, word: &str, value: JsonValue) -> Result<JsonValue, String> {
        let end = self.at + word.chars().count();
        if self
            .chars
            .get(self.at..end)
            .is_some_and(|got| got.iter().copied().eq(word.chars()))
        {
            self.at = end;
            Ok(value)
        } else {
            Err(format!("expected {word} at character {}", self.at))
        }
    }

    fn value(&mut self) -> Result<JsonValue, String> {
        self.blank();
        match self.peek() {
            Some('{') => self.object(),
            Some('[') => self.array(),
            Some('"') => self.string().map(JsonValue::String),
            Some('t') => self.word("true", JsonValue::Bool(true)),
            Some('f') => self.word("false", JsonValue::Bool(false)),
            Some('n') => self.word("null", JsonValue::Null),
            Some(c) if c == '-' || c.is_ascii_digit() => Ok(self.number()),
            _ => Err(format!("expected a JSON value at character {}", self.at)),
        }
    }

    fn number(&mut self) -> JsonValue {
        let start = self.at;
        while self
            .peek()
            .is_some_and(|c| c.is_ascii_digit() || "+-.eE".contains(c))
        {
            self.at += 1;
        }
        JsonValue::Number(self.chars[start..self.at].iter().collect())
    }

    fn string(&mut self) -> Result<String, String> {
        self.expect('"')?;
        let mut out = String::new();
        loop {
            let c = self.peek().ok_or("unterminated JSON string")?;
            self.at += 1;
            match c {
                '"' => return Ok(out),
                '\\' => out.push(self.escape()?),
                _ => out.push(c),
            }
        }
    }

    fn escape(&mut self) -> Result<char, String> {
        let c = self.peek().ok_or("unterminated JSON escape")?;
        self.at += 1;
        Ok(match c {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'b' => '\u{8}',
            'f' => '\u{c}',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => return self.unicode(),
            other => return Err(format!("unknown JSON escape \\{other}")),
        })
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let digits: String = self
            .chars
            .get(self.at..self.at + 4)
            .ok_or("short \\u escape")?
            .iter()
            .collect();
        self.at += 4;
        u32::from_str_radix(&digits, 16).map_err(|_| format!("bad \\u escape {digits}"))
    }

    fn unicode(&mut self) -> Result<char, String> {
        let high = self.hex4()?;
        let code = if (0xD800..0xDC00).contains(&high) {
            if self.chars.get(self.at..self.at + 2) != Some(&['\\', 'u']) {
                return Err("a high surrogate needs its low half".to_string());
            }
            self.at += 2;
            let low = self.hex4()?;
            0x10000 + ((high - 0xD800) << 10) + (low.wrapping_sub(0xDC00) & 0x3FF)
        } else {
            high
        };
        char::from_u32(code).ok_or_else(|| format!("\\u{code:x} is not a character"))
    }

    fn array(&mut self) -> Result<JsonValue, String> {
        self.expect('[')?;
        let mut items = Vec::new();
        self.blank();
        if self.peek() == Some(']') {
            self.at += 1;
            return Ok(JsonValue::Array(items));
        }
        loop {
            items.push(self.value()?);
            self.blank();
            match self.peek() {
                Some(',') => self.at += 1,
                Some(']') => {
                    self.at += 1;
                    return Ok(JsonValue::Array(items));
                }
                _ => return Err(format!("expected ',' or ']' at character {}", self.at)),
            }
        }
    }

    fn object(&mut self) -> Result<JsonValue, String> {
        self.expect('{')?;
        let mut pairs = Vec::new();
        self.blank();
        if self.peek() == Some('}') {
            self.at += 1;
            return Ok(JsonValue::Object(pairs));
        }
        loop {
            self.blank();
            let key = self.string()?;
            self.expect(':')?;
            pairs.push((key, self.value()?));
            self.blank();
            match self.peek() {
                Some(',') => self.at += 1,
                Some('}') => {
                    self.at += 1;
                    return Ok(JsonValue::Object(pairs));
                }
                _ => return Err(format!("expected ',' or '}}' at character {}", self.at)),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::read;
    use crate::emit::{write, JsonValue};

    #[test]
    fn reads_what_the_emitter_writes() {
        let text = "{\"beat\": {\"value\": \"beat-quiet\"}, \"n\": [1, -2, true, null], \"s\": \"a\\\"\\u00e9\"}";
        let value = read(text).expect("valid JSON");
        assert_eq!(read(&write(&value)).map(|v| write(&v)), Ok(write(&value)));
        let JsonValue::Object(pairs) = value else {
            panic!("an object")
        };
        assert_eq!(pairs.len(), 3);
    }

    #[test]
    fn refuses_trailing_text_and_bad_escapes() {
        assert!(read("{} x").is_err());
        assert!(read("\"\\q\"").is_err());
        assert!(read("[1,").is_err());
    }
}
