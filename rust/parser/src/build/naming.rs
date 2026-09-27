//! Pure name-shape conversions (mirrors `Hecks::Naming`) shared by the other derivations.

/// `"Pizzas::Order" -> "Order"`.
pub fn demodulise(type_name: &str) -> String {
    type_name
        .rsplit("::")
        .next()
        .unwrap_or(type_name)
        .to_string()
}

/// A bare command constant (`Account::Debit`) becomes `Account.Debit`; strings pass through.
///
/// Only the last `::` is rewritten, so `Banking::Account::Debit` -> `Banking::Account.Debit`.
pub fn command_ref(raw: &str) -> String {
    match crate::ruby_value::read(raw.trim()) {
        crate::ruby_value::Value::Str(s) => s,
        crate::ruby_value::Value::Bare(bare) => match bare.rsplit_once("::") {
            Some((path, command)) => format!("{path}.{command}"),
            None => bare,
        },
        other => crate::ruby_value::to_s(&other),
    }
}

/// Event reference of a process manager: a bare constant chain keeps only its last segment.
///
/// `SagaInterpreter` matches a bare `event.name`, never a `.`-qualified one.
pub fn event_name_ref(raw: &str) -> String {
    match crate::ruby_value::read(raw.trim()) {
        crate::ruby_value::Value::Str(s) => s,
        crate::ruby_value::Value::Bare(bare) => demodulise(&bare),
        other => crate::ruby_value::to_s(&other),
    }
}

/// `"PizzaName" -> "pizza_name"`, using the same two-pass split as `Hecks::Naming.snake`.
pub fn snake(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut pass1 = String::new();
    for (i, &ch) in chars.iter().enumerate() {
        let is_upper_run_boundary = ch.is_ascii_uppercase()
            && i > 0
            && chars[i - 1].is_ascii_uppercase()
            && i + 1 < chars.len()
            && chars[i + 1].is_ascii_lowercase();
        if is_upper_run_boundary {
            pass1.push('_');
        }
        pass1.push(ch);
    }

    let pass1_chars: Vec<char> = pass1.chars().collect();
    let mut pass2 = String::new();
    for (i, &ch) in pass1_chars.iter().enumerate() {
        let is_lower_to_upper_boundary = ch.is_ascii_uppercase()
            && i > 0
            && (pass1_chars[i - 1].is_ascii_lowercase() || pass1_chars[i - 1].is_ascii_digit());
        if is_lower_to_upper_boundary {
            pass2.push('_');
        }
        pass2.push(ch);
    }

    pass2.to_lowercase()
}

/// `"pizza_name" -> "PizzaName"`.
pub fn pascal(text: &str) -> String {
    text.split('_')
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect()
}

/// Pluralizes a snake-cased name: `y` -> `ies`, sibilants take `es`, else `s`.
pub fn plural(text: &str) -> String {
    if text.len() > 1 {
        let last = &text[text.len() - 1..];
        let before_last = text.chars().rev().nth(1);
        if last == "y" && !matches!(before_last, Some('a' | 'e' | 'i' | 'o' | 'u')) {
            return format!("{}ies", &text[..text.len() - 1]);
        }
    }
    for suffix in ["s", "x", "z", "ch", "sh"] {
        if text.ends_with(suffix) {
            return format!("{text}es");
        }
    }
    format!("{text}s")
}

/// Inverse of `plural` for `has_many` targets: `ies` -> `y`, trailing `s` dropped.
pub fn singularize(text: &str) -> String {
    if text.len() > 3 && text.ends_with("ies") {
        return format!("{}y", &text[..text.len() - 3]);
    }
    if text.len() > 1 && text.ends_with('s') {
        return text[..text.len() - 1].to_string();
    }
    text.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pluralizes_a_read_model_head_name() {
        assert_eq!(plural("state_style"), "state_styles");
        assert_eq!(plural("collection"), "collections");
        assert_eq!(plural("company"), "companies");
        assert_eq!(plural("box"), "boxes");
    }

    #[test]
    fn demodulises_a_namespaced_constant() {
        assert_eq!(demodulise("Pizzas::Order"), "Order");
        assert_eq!(demodulise("Order"), "Order");
    }

    #[test]
    fn command_refs_a_bare_constant_by_its_last_namespace_segment() {
        assert_eq!(command_ref("Account::Debit"), "Account.Debit");
        assert_eq!(
            command_ref("Banking::Account::Debit"),
            "Banking::Account.Debit"
        );
        assert_eq!(command_ref("Debit"), "Debit");
    }

    #[test]
    fn command_refs_a_legacy_quoted_string_unchanged() {
        assert_eq!(command_ref("\"Account.Debit\""), "Account.Debit");
    }
}
