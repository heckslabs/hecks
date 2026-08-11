//! The Rust side of `Hecksagain::Literal` (lib/hecksagain/literal.rb) — the
//! ONE pinned spelling for a captured Ruby literal on the wire, landed in
//! Stage 0b specifically so this module would have a single, explicit,
//! Ruby-version-independent format to match rather than `Hash#inspect`'s
//! own moving target (3.3 writes `{:value=>"credit"}`, 3.4 writes
//! `{value: "credit"}` for the identical Hash).
//!
//! `render` and `read` are exact mirrors of `Literal.render`/`Literal.read`
//! — nil -> "nil", booleans/numbers bare, Symbol -> ":name", String ->
//! "\"quoted\"" with explicit \/" escaping, Hash -> "{key: value}", Array
//! -> "[a, b]", recursive. Stage 2+ feeds this real captured-literal
//! strings from ir.json; Stage 1 only needs this to exist and agree with
//! the Ruby source byte-for-byte, which is what tests/fixtures exercises.

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Nil,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    Symbol(String),
    Hash(Vec<(String, Value)>),
    Array(Vec<Value>),
    /// A bare word that was never rendered by `Literal.render` in the first
    /// place — `Literal.read`'s own "tolerant of a bare word on purpose"
    /// fallback, kept distinct from `Str` so a round-trip through `render`
    /// doesn't silently wrap it in quotes it never had.
    Bare(String),
}

pub fn render(value: &Value) -> String {
    match value {
        Value::Nil => "nil".to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Int(n) => n.to_string(),
        Value::Float(f) => format_ruby_float(*f),
        Value::Symbol(name) => format!(":{name}"),
        Value::Str(text) => quote(text),
        Value::Bare(text) => text.clone(),
        Value::Hash(pairs) => {
            let body = pairs
                .iter()
                .map(|(key, held)| format!("{key}: {}", render(held)))
                .collect::<Vec<_>>()
                .join(", ");
            format!("{{{body}}}")
        }
        Value::Array(items) => {
            let body = items.iter().map(render).collect::<Vec<_>>().join(", ");
            format!("[{body}]")
        }
    }
}

/// Ruby's `Float#to_s` always carries at least one digit past the point
/// (`1.0`, never `1`) — mirrored here rather than delegated to Rust's own
/// float formatting, which prints a bare integer-valued float as `1` with
/// no decimal at all.
fn format_ruby_float(value: f64) -> String {
    let text = format!("{value}");
    if text.contains('.') || text.contains('e') || text.contains("inf") || text.contains("NaN") {
        text
    } else {
        format!("{text}.0")
    }
}

pub fn quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

/// Ruby's `Symbol#to_s`/`String#to_s` for a captured `Value` — DISTINCT
/// from `render`: no colon on a Symbol, no quotes on a String. Used only
/// where the Ruby source itself calls `.to_s` rather than
/// `Literal.render` — `IR::ValueObject#to_h`'s own `members` field
/// (`member.map { |field, value| [field.to_s, value.to_s] }`,
/// value_object.rb), confirmed against `spec/golden/ir/Pizzas.json`:
/// `member value: "small"` renders as `["value", "small"]`, never
/// `["value", "\"small\""]`.
pub fn to_s(value: &Value) -> String {
    match value {
        Value::Nil => String::new(),
        Value::Bool(b) => b.to_string(),
        Value::Int(n) => n.to_string(),
        Value::Float(f) => format_ruby_float(*f),
        Value::Symbol(name) => name.clone(),
        Value::Str(text) => text.clone(),
        Value::Bare(text) => text.clone(),
        // Not exercised anywhere in the pizzas corpus (no member/mutation
        // value is ever a nested Hash/Array) — Ruby's own Hash#to_s/
        // Array#to_s is `#inspect`-shaped and version-dependent the same
        // way `Hash#inspect` itself is (see this crate's own header on
        // why that hazard was pinned away for `render`). Falls back to
        // `render`'s own (stable, pinned) spelling rather than guess at
        // an unreachable case.
        Value::Hash(_) | Value::Array(_) => render(value),
    }
}

/// A quoted Ruby Symbol's OWN inner text, unescaped — `:"a.b"` -> `a.b`.
/// Distinct from `read`'s own (wire-format) Symbol handling: `read` never
/// sees a quoted symbol on the wire (`Literal.render` never spells one),
/// this is for SOURCE syntax a bluebook author actually writes
/// (`where(:"pizza.price_cents.cents" => ...)`, real corpus syntax).
/// `rest` is the text strictly after the leading `:`, already confirmed
/// to start and end with `"`.
pub fn unquote_for_symbol(rest: &str) -> String {
    unquote(rest)
}

pub fn read(text: &str) -> Value {
    let raw = text.trim();
    if raw.is_empty() || raw == "nil" {
        return Value::Nil;
    }
    if raw == "true" {
        return Value::Bool(true);
    }
    if raw == "false" {
        return Value::Bool(false);
    }
    if is_integer(raw) {
        if let Ok(n) = raw.parse::<i64>() {
            return Value::Int(n);
        }
    }
    if is_float(raw) {
        if let Ok(f) = raw.parse::<f64>() {
            return Value::Float(f);
        }
    }
    if let Some(name) = raw.strip_prefix(':') {
        return Value::Symbol(name.to_string());
    }
    if is_quoted(raw) {
        return Value::Str(unquote(raw));
    }
    if raw.starts_with('{') && raw.ends_with('}') {
        return read_hash(raw);
    }
    if raw.starts_with('[') && raw.ends_with(']') {
        return read_array(raw);
    }
    Value::Bare(raw.to_string())
}

fn is_integer(raw: &str) -> bool {
    let body = raw.strip_prefix('-').unwrap_or(raw);
    !body.is_empty() && body.chars().all(|c| c.is_ascii_digit())
}

fn is_float(raw: &str) -> bool {
    let body = raw.strip_prefix('-').unwrap_or(raw);
    let Some((int_part, frac_part)) = body.split_once('.') else { return false };
    !int_part.is_empty()
        && !frac_part.is_empty()
        && int_part.chars().all(|c| c.is_ascii_digit())
        && frac_part.chars().all(|c| c.is_ascii_digit())
}

fn is_quoted(raw: &str) -> bool {
    raw.len() >= 2 && raw.starts_with('"') && raw.ends_with('"')
}

fn unquote(raw: &str) -> String {
    let inner = &raw[1..raw.len() - 1];
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(ch) = chars.next() {
        if ch == '\\' {
            if let Some(next) = chars.next() {
                out.push(next);
            }
        } else {
            out.push(ch);
        }
    }
    out
}

fn read_hash(raw: &str) -> Value {
    let inner = &raw[1..raw.len() - 1];
    let pairs = split_items(inner)
        .into_iter()
        .map(|item| {
            let (key, held) = item.split_once(':').unwrap_or((item.as_str(), ""));
            (key.trim().to_string(), read(held.trim()))
        })
        .collect();
    Value::Hash(pairs)
}

fn read_array(raw: &str) -> Value {
    let inner = &raw[1..raw.len() - 1];
    Value::Array(split_items(inner).into_iter().map(|item| read(item.trim())).collect())
}

/// Split on the commas that are actually SEPARATORS — never one inside a
/// quoted string or a nested brace/bracket. The exact algorithm
/// `Hecksagain::Literal.split_items` uses, character-scanned rather than a
/// naive `split(",")` that would tear a quoted `"a, b"` in half.
pub fn split_items(body: &str) -> Vec<String> {
    let mut items = Vec::new();
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
            items.push(current.clone());
            current.clear();
        }
    }
    items.push(current);
    items.into_iter().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_the_pinned_spellings() {
        assert_eq!(render(&Value::Nil), "nil");
        assert_eq!(render(&Value::Bool(true)), "true");
        assert_eq!(render(&Value::Bool(false)), "false");
        assert_eq!(render(&Value::Symbol("amount".to_string())), ":amount");
        assert_eq!(render(&Value::Int(0)), "0");
        assert_eq!(render(&Value::Float(0.0)), "0.0");
        assert_eq!(render(&Value::Str("credit".to_string())), "\"credit\"");
        assert_eq!(render(&Value::Str("a\"b\\c".to_string())), "\"a\\\"b\\\\c\"");
        assert_eq!(
            render(&Value::Hash(vec![("value".to_string(), Value::Str("credit".to_string()))])),
            "{value: \"credit\"}"
        );
        assert_eq!(
            render(&Value::Array(vec![Value::Int(1), Value::Int(2)])),
            "[1, 2]"
        );
    }

    #[test]
    fn reads_back_what_render_wrote() {
        assert_eq!(read("nil"), Value::Nil);
        assert_eq!(read("true"), Value::Bool(true));
        assert_eq!(read(":amount"), Value::Symbol("amount".to_string()));
        assert_eq!(read("0"), Value::Int(0));
        assert_eq!(read("0.0"), Value::Float(0.0));
        assert_eq!(read("\"credit\""), Value::Str("credit".to_string()));
        assert_eq!(
            read("{value: \"credit\"}"),
            Value::Hash(vec![("value".to_string(), Value::Str("credit".to_string()))])
        );
        assert_eq!(read("[1, 2]"), Value::Array(vec![Value::Int(1), Value::Int(2)]));
        // a bare word never rendered stays a string reading, not nil/symbol
        assert_eq!(read("open"), Value::Bare("open".to_string()));
    }

    #[test]
    fn splits_only_top_level_commas() {
        assert_eq!(split_items("\"a, b\", 1"), vec!["\"a, b\"".to_string(), "1".to_string()]);
        assert_eq!(split_items("{a: 1, b: 2}, 3"), vec!["{a: 1, b: 2}".to_string(), "3".to_string()]);
    }
}
