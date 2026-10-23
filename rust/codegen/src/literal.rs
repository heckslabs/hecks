//! Port of `Literal.read` from `lib/hecks/literal.rb`, the inverse of `Literal.render`.
//! `Literal::from_json` covers values embedded raw in ir.json, which were never rendered.

use crate::json::{Json, Number};
use crate::ruby_value::{self, Value};
use crate::shared::ruby_to_i;

#[derive(Debug, Clone, PartialEq)]
pub enum Literal {
    Nil,
    Bool(bool),
    Int(i64),
    Float(f64),
    /// A Symbol, which JSON cannot represent; only `read` produces one (leading-colon strings).
    Symbol(String),
    Str(String),
    Hash(Vec<(String, Self)>),
    Array(Vec<Self>),
}

impl Literal {
    /// Converts a raw `Json` value structurally, with no text parsing and no Symbol case.
    pub fn from_json(value: &Json) -> Self {
        match value {
            Json::Null => Self::Nil,
            Json::Bool(b) => Self::Bool(*b),
            Json::Number(_) => match value.number() {
                Some(Number::Int(n)) => Self::Int(n),
                Some(Number::Float(n)) => Self::Float(n),
                None => Self::Nil,
            },
            Json::String(s) => Self::Str(s.clone()),
            Json::Array(items) => Self::Array(items.iter().map(Self::from_json).collect()),
            Json::Object(pairs) => Self::Hash(
                pairs
                    .iter()
                    .map(|(k, v)| (k.clone(), Self::from_json(v)))
                    .collect(),
            ),
        }
    }

    pub const fn as_hash(&self) -> Option<&[(String, Self)]> {
        match self {
            Self::Hash(pairs) => Some(pairs.as_slice()),
            _ => None,
        }
    }

    pub fn get(&self, key: &str) -> Option<&Self> {
        self.as_hash()?
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v)
    }
}

/// `Literal.read`: parses a rendered wire string back to a `Literal`.
///
/// Reads through the parser's shared `ruby_value::read`. A bare word becomes a `Str`. An integer
/// too large for `i64` (the shared reader returns it as `Bare`) becomes `Int(0)`, as `ruby_to_i`
/// always did: no corpus domain holds one, and a stable `0` keeps generation total.
pub fn read(text: &str) -> Literal {
    from_value(ruby_value::read(text))
}

fn from_value(value: Value) -> Literal {
    match value {
        Value::Nil => Literal::Nil,
        Value::Bool(b) => Literal::Bool(b),
        Value::Int(n) => Literal::Int(n),
        Value::Float(n) => Literal::Float(n),
        Value::Str(s) => Literal::Str(s),
        Value::Symbol(s) => Literal::Symbol(s),
        Value::Hash(pairs) => {
            Literal::Hash(pairs.into_iter().map(|(k, v)| (k, from_value(v))).collect())
        }
        Value::Array(items) => Literal::Array(items.into_iter().map(from_value).collect()),
        Value::Bare(text) if is_integer(&text) => Literal::Int(ruby_to_i(&text)),
        Value::Bare(text) => Literal::Str(text),
    }
}

/// `/\A-?\d+\z/`
fn is_integer(raw: &str) -> bool {
    let s = raw.strip_prefix('-').unwrap_or(raw);
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

/// `naming.rb#literal_rhs` for a `Literal`: String/Integer/Float/Boolean, else panics.
#[allow(
    clippy::panic,
    reason = "a drifted exemplar or invalid IR aborts generation on purpose"
)]
pub fn literal_rhs(literal: &Literal) -> String {
    match literal {
        Literal::Str(s) => format!("{}.to_string()", crate::naming::ruby_inspect_string(s)),
        Literal::Int(n) => n.to_string(),
        Literal::Float(_) => ruby_float_to_s(literal),
        Literal::Bool(b) => b.to_string(),
        other => panic!("unsupported literal mutation source {other:?} — not one of String/Integer/Float/Boolean"),
    }
}

fn ruby_float_to_s(literal: &Literal) -> String {
    match literal {
        Literal::Float(n) => {
            let text = format!("{n}");
            if text.contains('.') || text.contains('e') || text.contains('E') {
                text
            } else {
                format!("{text}.0")
            }
        }
        _ => unreachable!(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(text: &str) -> Literal {
        Literal::Str(text.to_string())
    }

    #[test]
    fn reads_scalars() {
        assert_eq!(read(""), Literal::Nil);
        assert_eq!(read("nil"), Literal::Nil);
        assert_eq!(read("true"), Literal::Bool(true));
        assert_eq!(read("-12"), Literal::Int(-12));
        assert_eq!(read("1.5"), Literal::Float(1.5));
        assert_eq!(read(":name"), Literal::Symbol("name".to_string()));
        assert_eq!(read(r#""a\"b""#), s("a\"b"));
    }

    #[test]
    fn reads_collections() {
        assert_eq!(
            read(r#"[1, "x"]"#),
            Literal::Array(vec![Literal::Int(1), s("x")])
        );
        assert_eq!(
            read("{a: 1, b: :c}"),
            Literal::Hash(vec![
                ("a".to_string(), Literal::Int(1)),
                ("b".to_string(), Literal::Symbol("c".to_string()))
            ])
        );
    }

    #[test]
    fn bare_word_is_a_string() {
        assert_eq!(read("Widget"), s("Widget"));
    }

    #[test]
    fn overflowing_integer_is_zero_like_ruby_to_i() {
        assert_eq!(read("99999999999999999999"), Literal::Int(0));
        assert_eq!(read("-99999999999999999999"), Literal::Int(0));
    }

    #[test]
    fn adjacent_and_single_quoted_strings() {
        assert_eq!(read(r#""a" "b""#), s("ab"));
        assert_eq!(read(r"'it\'s'"), s("it's"));
    }

    #[test]
    fn from_json_and_get() {
        let hash = read("{a: 1}");
        assert_eq!(hash.get("a"), Some(&Literal::Int(1)));
        assert_eq!(Literal::from_json(&Json::Null), Literal::Nil);
    }
}
