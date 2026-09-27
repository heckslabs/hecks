//! Mirror of `Hecks::Literal` (lib/hecks/literal.rb): the pinned wire spelling of a captured
//! Ruby literal, independent of the Ruby version's `Hash#inspect` format.

/// A captured Ruby literal.
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
    /// A bare word `Literal.read` tolerates; kept apart from `Str` so `render` adds no quotes.
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

/// Ruby's `Float#to_s` always keeps a digit after the point (`1.0`); Rust prints `1`.
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

/// Ruby's `#to_s` of a `Value`: no colon on a Symbol, no quotes on a String.
/// For where Ruby calls `.to_s` rather than `Literal.render`, e.g. `IR::ValueObject#to_h`.
pub fn to_s(value: &Value) -> String {
    match value {
        Value::Nil => String::new(),
        Value::Bool(b) => b.to_string(),
        Value::Int(n) => n.to_string(),
        Value::Float(f) => format_ruby_float(*f),
        Value::Symbol(name) => name.clone(),
        Value::Str(text) => text.clone(),
        Value::Bare(text) => text.clone(),
        // Ruby's `Hash#to_s`/`Array#to_s` is version-dependent; use the pinned `render` form.
        Value::Hash(_) | Value::Array(_) => render(value),
    }
}

/// Unescapes the inner text of a quoted symbol in bluebook source, `:"a.b"` -> `a.b`.
/// `rest` is the text after the leading `:`, already confirmed to start and end with `"`.
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
    // Adjacent literals (`"a" "b"`) concatenate in Ruby; check before the single-literal
    // branches, which would slice `a" "b` out of the middle.
    if raw.starts_with('"') || raw.starts_with('\'') {
        if let Some((joined, consumed)) = scan_adjacent_strings(raw) {
            if consumed == raw.chars().count() {
                return Value::Str(joined);
            }
        }
    }
    if is_quoted(raw) {
        return Value::Str(unquote(raw));
    }
    // Single-quoted literals appear in source (e.g. regex patterns) though `Literal.render`
    // never emits them. Only `\\` and `\'` are escapes, so this is not `unquote`.
    if is_single_quoted(raw) {
        return Value::Str(unquote_single(raw));
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
    let Some((int_part, frac_part)) = body.split_once('.') else {
        return false;
    };
    !int_part.is_empty()
        && !frac_part.is_empty()
        && int_part.chars().all(|c| c.is_ascii_digit())
        && frac_part.chars().all(|c| c.is_ascii_digit())
}

fn is_quoted(raw: &str) -> bool {
    raw.len() >= 2 && raw.starts_with('"') && raw.ends_with('"')
}

fn is_single_quoted(raw: &str) -> bool {
    raw.len() >= 2 && raw.starts_with('\'') && raw.ends_with('\'')
}

/// Unescapes a Ruby single-quoted body: only `\\` and `\'` are escapes, other backslashes stay.
fn unquote_single(raw: &str) -> String {
    unescape_single_quoted_inner(&raw[1..raw.len() - 1])
}

fn unescape_single_quoted_inner(inner: &str) -> String {
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\\' {
            match chars.peek() {
                Some('\\') => {
                    out.push('\\');
                    chars.next();
                }
                Some('\'') => {
                    out.push('\'');
                    chars.next();
                }
                _ => out.push('\\'),
            }
        } else {
            out.push(ch);
        }
    }
    out
}

fn unquote(raw: &str) -> String {
    unescape_double_quoted_inner(&raw[1..raw.len() - 1])
}

fn unescape_double_quoted_inner(inner: &str) -> String {
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

/// Scans adjacent quoted literals (either quote style, whitespace-separated) from index 0.
/// Returns their unescaped concatenation and the chars consumed, or `None` if `raw` does not
/// start with a closed literal. Callers compare `consumed` to the full length to tell a whole
/// string expression from trailing text.
fn scan_adjacent_strings(raw: &str) -> Option<(String, usize)> {
    let chars: Vec<char> = raw.chars().collect();
    let mut i = 0usize;
    let mut out = String::new();
    let mut matched_any = false;

    loop {
        if matched_any {
            let mut j = i;
            while j < chars.len() && chars[j].is_whitespace() {
                j += 1;
            }
            if j >= chars.len() || (chars[j] != '"' && chars[j] != '\'') {
                break;
            }
            i = j;
        }

        // Defensive: return `None` rather than panic on an empty or odd `raw`.
        let Some(&quote) = chars.get(i).filter(|c| **c == '"' || **c == '\'') else {
            return None;
        };

        let start = i;
        i += 1;
        let mut escaping = false;
        let mut closed = false;
        while i < chars.len() {
            let ch = chars[i];
            if escaping {
                escaping = false;
                i += 1;
                continue;
            }
            if ch == '\\' {
                escaping = true;
                i += 1;
                continue;
            }
            if ch == quote {
                i += 1;
                closed = true;
                break;
            }
            i += 1;
        }
        if !closed {
            return None;
        }

        let inner: String = chars[start + 1..i - 1].iter().collect();
        out.push_str(&if quote == '"' {
            unescape_double_quoted_inner(&inner)
        } else {
            unescape_single_quoted_inner(&inner)
        });
        matched_any = true;
    }

    Some((out, i))
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
    Value::Array(
        split_items(inner)
            .into_iter()
            .map(|item| read(item.trim()))
            .collect(),
    )
}

/// Splits on commas outside quotes and nested braces, brackets and parens.
///
/// Unlike `Hecks::Literal.split_items` it also tracks parens, so a nested call such as
/// `one_of("a", "b")` inside an argument list stays in one segment.
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
        if ch == '{' || ch == '[' || ch == '(' {
            depth += 1;
        }
        if ch == '}' || ch == ']' || ch == ')' {
            depth -= 1;
        }
        if ch == ',' && depth == 0 {
            current.pop();
            items.push(current.clone());
            current.clear();
        }
    }
    items.push(current);
    items
        .into_iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
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
        assert_eq!(
            render(&Value::Str("a\"b\\c".to_string())),
            "\"a\\\"b\\\\c\""
        );
        assert_eq!(
            render(&Value::Hash(vec![(
                "value".to_string(),
                Value::Str("credit".to_string())
            )])),
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
            Value::Hash(vec![(
                "value".to_string(),
                Value::Str("credit".to_string())
            )])
        );
        assert_eq!(
            read("[1, 2]"),
            Value::Array(vec![Value::Int(1), Value::Int(2)])
        );
        // a bare word never rendered stays a string reading, not nil/symbol
        assert_eq!(read("open"), Value::Bare("open".to_string()));
    }

    #[test]
    fn splits_only_top_level_commas() {
        assert_eq!(
            split_items("\"a, b\", 1"),
            vec!["\"a, b\"".to_string(), "1".to_string()]
        );
        assert_eq!(
            split_items("{a: 1, b: 2}, 3"),
            vec!["{a: 1, b: 2}".to_string(), "3".to_string()]
        );
    }

    #[test]
    fn concatenates_three_adjacent_literals_mixing_quote_styles() {
        assert_eq!(read("\"a\" 'b' \"c\""), Value::Str("abc".to_string()));
    }

    #[test]
    fn does_not_treat_a_quoted_string_followed_by_other_text_as_concatenation() {
        // `"a" foo` is not two adjacent literals: `scan_adjacent_strings` consumes less than
        // the whole input, so `read` falls through to `Value::Bare`.
        assert_eq!(read("\"a\" foo"), Value::Bare("\"a\" foo".to_string()));
    }
}
