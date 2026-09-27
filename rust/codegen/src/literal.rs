//! Port of `Literal.read` from `lib/hecks/literal.rb`, the inverse of `Literal.render`.
//! `Literal::from_json` covers values embedded raw in ir.json, which were never rendered.

use crate::json::Json;

#[derive(Debug, Clone, PartialEq)]
pub enum Literal {
    Nil,
    Bool(bool),
    Int(i64),
    Float(f64),
    /// A Symbol, which JSON cannot represent; only `read` produces one (leading-colon strings).
    Symbol(String),
    Str(String),
    Hash(Vec<(String, Literal)>),
    Array(Vec<Literal>),
}

impl Literal {
    /// Converts a raw `Json` value structurally, with no text parsing and no Symbol case.
    pub fn from_json(value: &Json) -> Literal {
        match value {
            Json::Null => Literal::Nil,
            Json::Bool(b) => Literal::Bool(*b),
            Json::Int(n) => Literal::Int(*n),
            Json::Float(n) => Literal::Float(*n),
            Json::String(s) => Literal::Str(s.clone()),
            Json::Array(items) => Literal::Array(items.iter().map(Literal::from_json).collect()),
            Json::Object(pairs) => Literal::Hash(pairs.iter().map(|(k, v)| (k.clone(), Literal::from_json(v))).collect()),
        }
    }

    pub fn as_hash(&self) -> Option<&[(String, Literal)]> {
        match self {
            Literal::Hash(pairs) => Some(pairs.as_slice()),
            _ => None,
        }
    }

    pub fn get(&self, key: &str) -> Option<&Literal> {
        self.as_hash()?.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }
}

/// `Literal.read`: parses a rendered wire string back to a `Literal`.
///
/// Anything not matching a more specific shape, including a bare word, becomes a `Str`.
pub fn read(text: &str) -> Literal {
    let raw = text.trim();
    if raw.is_empty() || raw == "nil" {
        return Literal::Nil;
    }
    if raw == "true" {
        return Literal::Bool(true);
    }
    if raw == "false" {
        return Literal::Bool(false);
    }
    if is_integer(raw) {
        return Literal::Int(ruby_to_i(raw));
    }
    if is_float(raw) {
        return Literal::Float(raw.parse::<f64>().unwrap_or(0.0));
    }
    if let Some(rest) = raw.strip_prefix(':') {
        return Literal::Symbol(rest.to_string());
    }
    if is_quoted(raw) {
        return Literal::Str(unquote(raw));
    }
    if raw.starts_with('{') && raw.ends_with('}') {
        return read_hash(raw);
    }
    if raw.starts_with('[') && raw.ends_with(']') {
        return read_array(raw);
    }

    Literal::Str(raw.to_string())
}

/// `/\A-?\d+\z/`
fn is_integer(raw: &str) -> bool {
    let s = raw.strip_prefix('-').unwrap_or(raw);
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

/// `/\A-?\d+\.\d+\z/`
fn is_float(raw: &str) -> bool {
    let s = raw.strip_prefix('-').unwrap_or(raw);
    let Some((int_part, frac_part)) = s.split_once('.') else { return false };
    !int_part.is_empty() && !frac_part.is_empty() && int_part.bytes().all(|b| b.is_ascii_digit()) && frac_part.bytes().all(|b| b.is_ascii_digit())
}

fn ruby_to_i(raw: &str) -> i64 {
    raw.parse().unwrap_or(0)
}

fn is_quoted(raw: &str) -> bool {
    raw.len() >= 2 && raw.starts_with('"') && raw.ends_with('"')
}

/// Drops the surrounding quotes, then unescapes any backslash-escaped character.
fn unquote(raw: &str) -> String {
    let inner = &raw[1..raw.len() - 1];
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            if let Some(next) = chars.next() {
                out.push(next);
                continue;
            }
        }
        out.push(c);
    }
    out
}

fn read_hash(raw: &str) -> Literal {
    let inner = &raw[1..raw.len() - 1];
    let pairs = split_items(inner)
        .into_iter()
        .map(|item| {
            // Splits at the first ":" only, like Ruby's `partition`; field names have none.
            match item.find(':') {
                Some(idx) => {
                    let key = item[..idx].trim().to_string();
                    let held = &item[idx + 1..];
                    (key, read(held))
                }
                None => (item.trim().to_string(), read("")),
            }
        })
        .collect();
    Literal::Hash(pairs)
}

fn read_array(raw: &str) -> Literal {
    let inner = &raw[1..raw.len() - 1];
    Literal::Array(split_items(inner).into_iter().map(|item| read(&item)).collect())
}

/// `naming.rb#literal_rhs` for a `Literal`: String/Integer/Float/Boolean, else panics.
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

/// Splits on commas outside quoted strings and nested braces/brackets.
fn split_items(body: &str) -> Vec<String> {
    let mut items: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut depth: i32 = 0;
    let mut quoting = false;
    let mut escaping = false;

    for ch in body.chars() {
        current.push(ch);
        if escaping {
            escaping = false;
            continue;
        }
        if quoting && ch == '\\' {
            escaping = true;
            continue;
        }
        if ch == '"' {
            quoting = !quoting;
            continue;
        }
        if quoting {
            continue;
        }

        if ch == '{' || ch == '[' {
            depth += 1;
        }
        if ch == '}' || ch == ']' {
            depth -= 1;
        }
        if ch == ',' && depth == 0 {
            current.pop();
            items.push(std::mem::take(&mut current));
        }
    }
    items.push(current);
    items.into_iter().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
}
