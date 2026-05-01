/// Convert a string to snake_case.
///
/// Matches Ruby's ActiveSupport `#underscore` behavior for acronyms:
/// consecutive uppercase letters are treated as a single acronym, so
/// `DNAProfile` becomes `dna_profile` (not `d_n_a_profile`), and
/// `APIEndpoint` becomes `api_endpoint`. An underscore is inserted:
///   * before an uppercase letter preceded by a lowercase letter
///     (normal word boundary, e.g. `CamelCase` -> `camel_case`), or
///   * before an uppercase letter preceded by another uppercase letter
///     AND followed by a lowercase letter (acronym-ending boundary,
///     e.g. the `E` in `APIEndpoint`).
pub fn to_snake_case(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut result = String::with_capacity(s.len() + 4);
    for i in 0..chars.len() {
        let c = chars[i];
        if c.is_uppercase() && i > 0 {
            let prev = chars[i - 1];
            let next = chars.get(i + 1).copied();
            let prev_lower = prev.is_lowercase() || prev.is_ascii_digit();
            let acronym_end = prev.is_uppercase()
                && next.map(|n| n.is_lowercase()).unwrap_or(false);
            if prev_lower || acronym_end {
                result.push('_');
            }
        }
        result.push(c.to_lowercase().next().unwrap_or(c));
    }
    result
}

