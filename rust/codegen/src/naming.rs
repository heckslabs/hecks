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

/// Generated from the `RustReservedWord`/`CargoReservedName` vocabularies by
/// `bin/project_reserved_names` — the same tables `naming.rb` reads.
pub use crate::reserved_names::{CARGO_RESERVED_DOMAIN_NAMES, RUST_KEYWORDS};

/// `/\A[a-z_][a-z0-9_]*\z/` — a plain lowercase Rust identifier.
fn plain_lower_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c == '_' || c.is_ascii_lowercase())
        && chars.all(|c| c == '_' || c.is_ascii_lowercase() || c.is_ascii_digit())
}

/// Mirrors `legal_aggregate_mod_identifier?` — the identifier-shape half
/// only, against the downcased name.
pub fn legal_aggregate_mod_identifier(name: &str) -> bool {
    plain_lower_identifier(&name.to_lowercase())
}

/// Mirrors `valid_domain_mod_name?` — shape, and neither a Rust keyword nor
/// a reserved Cargo.toml key.
pub fn valid_domain_mod_name(name: &str) -> bool {
    plain_lower_identifier(name) && !RUST_KEYWORDS.contains(&name) && !CARGO_RESERVED_DOMAIN_NAMES.contains(&name)
}

/// Port of `RustProjection::Projector.reserved_name_refusal` (BUG#124) —
/// `None` when every aggregate name and the domain's module name are usable,
/// else the byte-identical refusal the Ruby generator raises. Aggregates are
/// checked (and reported) before the domain name, all at once.
pub fn reserved_name_refusal(source_label: &str, mod_name: &str, aggregate_names: &[&str]) -> Option<String> {
    let refused: Vec<&str> = aggregate_names
        .iter()
        .copied()
        .filter(|name| {
            let module = name.to_lowercase();
            RUST_KEYWORDS.contains(&module.as_str()) || !legal_aggregate_mod_identifier(name)
        })
        .collect();
    if let Some(first) = refused.first() {
        let names = refused.iter().map(|name| format!("{name:?}")).collect::<Vec<_>>().join(", ");
        return Some(format!(
            "{source_label}: aggregate name(s) {names} can't be used as-is — downcased, each becomes a bare Rust \
             module identifier (`pub mod {};`) and a generated file name, and at least one is not a plain identifier \
             or is a Rust keyword (RustReservedWord). Module names get no raw-identifier (r#name) escape hatch — \
             rename the aggregate.",
            first.to_lowercase()
        ));
    }
    if valid_domain_mod_name(mod_name) {
        return None;
    }
    Some(format!(
        "{source_label}: domain module name {mod_name:?} can't be used as-is — it has to double as a Rust module \
         identifier and a Cargo feature name, and this one is either not a plain lowercase identifier, is a Rust \
         keyword (RustReservedWord), or is a reserved Cargo.toml key (CargoReservedName). Rename the domain."
    ))
}

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
/// identifier — split on any run of non-alphanumeric characters (see
/// naming.rb's own header on why plain `_`/whitespace splitting broke on
/// glob-shaped members like `"*.port"`).
///
/// `Self` — the one capitalized Rust keyword — is renamed by spelling:
/// `SelfType` / `SelfValue` (naming.rb's own `closed_set_variant` header).
pub fn closed_set_variant(value: &str) -> String {
    let variant = value
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|s| !s.is_empty())
        .map(capitalize)
        .collect::<Vec<_>>()
        .join("");
    if variant != "Self" {
        return variant;
    }
    if value.starts_with('S') { "SelfType".to_string() } else { "SelfValue".to_string() }
}

fn capitalize(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        None => String::new(),
        Some(first) => first.to_uppercase().collect::<String>() + &chars.as_str().to_lowercase(),
    }
}

/// Port of `Hecks::Naming.snake` —
/// `gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase`.
pub fn snake(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut first = String::new();
    for (i, &c) in chars.iter().enumerate() {
        let next_upper = chars.get(i + 1).is_some_and(|n| n.is_ascii_uppercase());
        let then_lower = chars.get(i + 2).is_some_and(|n| n.is_ascii_lowercase());
        first.push(c);
        if c.is_ascii_uppercase() && next_upper && then_lower {
            first.push('_');
        }
    }
    let chars: Vec<char> = first.chars().collect();
    let mut second = String::new();
    for (i, &c) in chars.iter().enumerate() {
        second.push(c);
        let next_upper = chars.get(i + 1).is_some_and(|n| n.is_ascii_uppercase());
        if (c.is_ascii_lowercase() || c.is_ascii_digit()) && next_upper {
            second.push('_');
        }
    }
    second.to_lowercase()
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

/// Mirrors `fielded_capable_nested?`: ordinary value objects and
/// single-field closed-set enums implement `Fielded`; multi-field closed-set
/// tables do not.
pub fn fielded_capable_nested(vo: &crate::json::Json) -> bool {
    !vo.get("closed_set").map(crate::json::Json::as_bool).unwrap_or(false)
        || vo.get("attributes").map(crate::json::Json::each).unwrap_or(&[]).len() == 1
}

/// The `Fielded` implementation Ruby emits beside a single-field closed-set
/// enum. Its generic field surface is the same `"value"` object shape used by
/// that enum's existing JSON codec.
pub fn emit_closed_set_fielded_impl(vo: &crate::json::Json) -> String {
    let name = rust_ident(vo.get("name").and_then(crate::json::Json::as_str).unwrap_or(""));
    let arms = vo.get("members").map(crate::json::Json::each).unwrap_or(&[]).iter().filter_map(|row| {
        let pair = row.as_array()?.first()?.as_array()?;
        let raw = pair.get(1)?.to_s();
        Some(format!("{name}::{} => {}.to_string(),", closed_set_variant(&raw), ruby_inspect_string(&raw)))
    }).collect::<Vec<_>>().join(" ");

    format!(
        "impl crate::kernel::Fielded for {name} {{\n    fn field(&self, name: &str) -> Option<crate::kernel::Field<'_>> {{\n        use crate::kernel::{{Field, Value}};\n        match name {{\n            \"value\" => Some(Field::Value(Value::Str(match self {{ {arms} }}))),\n            _ => None,\n        }}\n    }}\n    fn as_scalar(&self) -> Option<crate::kernel::Value> {{\n        match self.field(\"value\") {{ Some(crate::kernel::Field::Value(v)) => Some(v), _ => None }}\n    }}\n}}"
    )
}

/// A literal mutation-source RHS — mirrors `naming.rb#literal_rhs`. Takes
/// the already-parsed `crate::ruby_value::Value`-shaped JSON literal
/// (String/Integer/Float/Bool) this crate reads out of `ir.json`.
pub fn literal_rhs(literal: &crate::json::Json) -> String {
    match literal {
        crate::json::Json::String(s) => format!("{}.to_string()", ruby_inspect_string(s)),
        // `Integer, Float then literal.to_s` — one Ruby case, but `to_s`
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_an_aggregate_whose_module_name_is_a_rust_keyword() {
        let refusal = reserved_name_refusal("shop", "shop", &["Pizza", "Match", "Type"]).expect("refused");
        assert!(refusal.starts_with("shop: aggregate name(s) \"Match\", \"Type\" can't be used as-is"), "{refusal}");
        assert!(refusal.contains("`pub mod match;`"), "{refusal}");
        assert!(refusal.contains("Rust keyword"), "{refusal}");
    }

    #[test]
    fn refuses_an_aggregate_name_that_is_not_a_plain_identifier() {
        assert!(reserved_name_refusal("shop", "shop", &["My-App"]).is_some());
        assert!(reserved_name_refusal("shop", "shop", &[""]).is_some());
    }

    #[test]
    fn refuses_a_domain_module_name_that_is_a_keyword_or_a_cargo_key() {
        for name in ["crate", "type", "package", "default", "version"] {
            let refusal = reserved_name_refusal("label", name, &["Widget"]).expect("refused");
            assert!(refusal.starts_with(&format!("label: domain module name {name:?} can't be used as-is")), "{refusal}");
        }
    }

    #[test]
    fn accepts_ordinary_names_and_cargo_keys_as_aggregate_names() {
        assert_eq!(reserved_name_refusal("shop", "shop", &["Pizza", "Version", "Default"]), None);
    }
}
