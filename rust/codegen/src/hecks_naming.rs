//! Port of the `lib/hecks/naming.rb` functions this crate's ported
//! scope actually needs — `Naming.snake` (used by `emit_extract_id`'s own
//! `reference_key`), plus `Naming.demodulise`/`Naming.reference_key`
//! (needed by `json_codec.rb#command_argument_allowlist`, Stage 7's
//! command-codegen slice). Not the whole file: nothing else in this
//! crate's ported scope calls into `Hecks::Naming`.

/// `type.to_s.split("::").last.to_s`
pub fn demodulise(type_name: &str) -> String {
    type_name.rsplit("::").next().unwrap_or(type_name).to_string()
}

/// `snake(demodulise(type)).to_sym`
pub fn reference_key(type_name: &str) -> String {
    snake(&demodulise(type_name))
}

/// `text.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/,
/// '\1_\2').downcase` — the two sequential gsubs collapse to one combined
/// rule for a single forward pass: insert `_` before an uppercase letter
/// when the previous character is lowercase/digit (rule 2), OR the
/// previous character is uppercase AND the next character is lowercase
/// (rule 1 — the "acronym, then a new word starts" case).
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
