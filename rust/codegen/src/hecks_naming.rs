//! Port of the subset of `lib/hecks/naming.rb` that codegen calls:
//! `snake`, `demodulise` and `reference_key`.

/// `type.to_s.split("::").last.to_s`
pub fn demodulise(type_name: &str) -> String {
    type_name.rsplit("::").next().unwrap_or(type_name).to_string()
}

/// `snake(demodulise(type)).to_sym`
pub fn reference_key(type_name: &str) -> String {
    snake(&demodulise(type_name))
}

/// CamelCase to snake_case, matching Ruby's two-gsub `Naming.snake` in a single pass.
///
/// Inserts `_` before an uppercase letter that follows a lowercase letter or digit, or that
/// ends an acronym (uppercase before, lowercase after).
pub fn snake(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::new();
    for (i, &c) in chars.iter().enumerate() {
        if c.is_ascii_uppercase() && i > 0 {
            let prev = chars[i - 1];
            let next = chars.get(i + 1).copied();
            let insert = (prev.is_ascii_lowercase() || prev.is_ascii_digit()) || (prev.is_ascii_uppercase() && next.map(|n| n.is_ascii_lowercase()).unwrap_or(false));
            if insert {
                out.push('_');
            }
        }
        out.push(c);
    }
    out.to_lowercase()
}
