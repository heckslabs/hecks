//! Port of `rust/project/naming.rb` — read that file's own comments for
//! the full rationale behind each rule; this mirrors its algorithm
//! directly, function for function.

pub fn scalar_rust_type(type_name: &str) -> Option<&'static str> {
    match type_name {
        "String" => Some("String"),
        "Integer" => Some("i64"),
        "Float" => Some("f64"),
        _ => None,
    }
}

pub fn reference_type(type_name: &str) -> bool {
    type_name.starts_with("Reference<")
}

/// `X` out of `Reference<X>` — `None` for anything that isn't a reference
/// type at all.
pub fn reference_target(type_name: &str) -> Option<&str> {
    type_name.strip_prefix("Reference<").and_then(|rest| rest.strip_suffix('>'))
}

pub fn effective_scalar_type(type_name: &str) -> Option<&'static str> {
    if reference_type(type_name) {
        return Some("String");
    }
    match type_name {
        "String" => Some("String"),
        "Integer" => Some("Integer"),
        "Float" => Some("Float"),
        _ => None,
    }
}

pub fn rust_type(type_name: &str, list: bool) -> String {
    let scalar = effective_scalar_type(type_name);
    let inner = match scalar {
        Some(s) => scalar_rust_type(s).unwrap().to_string(),
        None => rust_ident(type_name),
    };
    if list {
        format!("Vec<{inner}>")
    } else {
        inner
    }
}

pub fn rust_ident(name: &str) -> String {
    name.chars().filter(|c| c.is_ascii_alphanumeric()).collect()
}

/// `cmd.gsub(/(?<=.)([A-Z])/, '_\1').downcase` — insert `_` before every
/// uppercase letter that isn't the very first character, then lowercase.
pub fn dispatch_fn_name(cmd: &str) -> String {
    let mut out = String::new();
    for (i, c) in cmd.chars().enumerate() {
        if i > 0 && c.is_ascii_uppercase() {
            out.push('_');
        }
        out.push(c);
    }
    out.to_lowercase()
}

pub const RUST_KEYWORDS: &[&str] = &[
    "as", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
    "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while", "abstract", "become", "box", "do", "final", "macro", "override", "priv",
    "typeof", "unsized", "virtual", "yield", "try",
];

pub fn rust_field(name: &str) -> String {
    name.to_string()
}

pub fn rust_ident_field(name: &str) -> String {
    let field = rust_field(name);
    if RUST_KEYWORDS.contains(&field.as_str()) {
        format!("r#{field}")
    } else {
        field
    }
}

/// A closed-set member's value is business text, not a pre-sanitized Rust
/// identifier — split on ANY run of non-alphanumeric characters (see
/// naming.rb's own header on why plain `_`/whitespace splitting broke on
/// glob-shaped members like `"*.port"`).
pub fn closed_set_variant(value: &str) -> String {
    value
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|s| !s.is_empty())
        .map(capitalize)
        .collect::<Vec<_>>()
        .join("")
}

fn capitalize(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        None => String::new(),
        Some(first) => first.to_uppercase().collect::<String>() + &chars.as_str().to_lowercase(),
    }
}

/// `name.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').upcase`
pub fn screaming_snake(name: &str) -> String {
    let chars: Vec<char> = name.chars().collect();
    let mut out = String::new();
    for (i, &c) in chars.iter().enumerate() {
        if i > 0 {
            let prev = chars[i - 1];
            if (prev.is_ascii_lowercase() || prev.is_ascii_digit()) && c.is_ascii_uppercase() {
                out.push('_');
            }
        }
        out.push(c);
    }
    out.to_uppercase()
}

pub fn scalar_to_value(type_name: &str, rust_expr: &str) -> Option<String> {
    match type_name {
        "String" => Some(format!("Value::Str({rust_expr}.clone())")),
        "Integer" => Some(format!("Value::Int({rust_expr})")),
        "Float" => Some(format!("Value::Float({rust_expr})")),
        _ => None,
    }
}

/// A literal mutation-source RHS — mirrors `naming.rb#literal_rhs`. Takes
/// the already-parsed `crate::ruby_value::Value`-shaped JSON literal
/// (String/Integer/Float/Bool) this crate reads out of `ir.json`.
pub fn literal_rhs(literal: &crate::json::Json) -> String {
    match literal {
        crate::json::Json::String(s) => format!("{}.to_string()", ruby_inspect_string(s)),
        // `Integer, Float then literal.to_s` — ONE Ruby case, but `to_s`
        // renders differently per real type (`0.to_s == "0"`, `0.0.to_s ==
        // "0.0"`) — kept as two Rust match arms so a whole-number Float
        // default still renders as a valid `f64` literal (`0.0`, not the
        // integer-typed `0` that would fail to unify with the `x.as_f64()`
        // branch it sits beside in `scalar_from_json_expr`'s own output).
        crate::json::Json::Int(n) => n.to_string(),
        crate::json::Json::Float(_) => literal.to_s(),
        crate::json::Json::Bool(b) => b.to_string(),
        other => panic!("unsupported literal mutation source {other:?} — not one of String/Integer/Float/Boolean"),
    }
}

/// Ruby's `String#inspect` — a double-quoted, backslash/quote-escaped
/// literal. Shared by every codegen site that needs to embed a Ruby-
/// literal-shaped string constant in generated Rust text (matching Rust's
/// own escaping for the common cases both languages agree on).
pub fn ruby_inspect_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}
