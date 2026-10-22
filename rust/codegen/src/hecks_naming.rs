//! The one Rust port of `lib/hecks/naming.rb`: `demodulise`, `reference_key`, `snake`, `pascal`,
//! `plural` and `singularize`, std-only so every Cargo project here can compile this same file
//! with `#[path = "..."] mod hecks_naming;` instead of keeping a copy that can drift.
//!
//! Each function follows the Ruby rule for rule. The Ruby patterns are ASCII-only while
//! `String#downcase` and `String#upcase` use the full Unicode mapping a character at a time, so
//! the boundaries below test ASCII and the case folds do not.
//! `spec/fixtures/naming_vectors.json` is asserted by both runtimes.

/// `type.to_s.split("::").last.to_s`. Ruby's `split` drops trailing empty parts, so a trailing
/// `::` names the segment before it.
pub fn demodulise(type_name: &str) -> String {
    type_name
        .split("::")
        .filter(|part| !part.is_empty())
        .last()
        .unwrap_or("")
        .to_string()
}

/// `snake(demodulise(type)).to_sym`
pub fn reference_key(type_name: &str) -> String {
    snake(&demodulise(type_name))
}

/// `Naming.snake`: PascalCase or camelCase to snake_case.
///
/// The two Ruby `gsub` passes (`([A-Z]+)([A-Z][a-z])` then `([a-z\d])([A-Z])`), then the
/// per-character Unicode downcase.
pub fn snake(name: &str) -> String {
    ruby_downcase(&word_boundary(&acronym_boundary(name)))
}

/// Lowercases the way Ruby's `String#downcase` does: each character on its own, with the full
/// Unicode mapping. `str::to_lowercase` differs in one place, a word-final capital sigma, which
/// it turns into the final form `ς` where Ruby gives `σ`; and `to_ascii_lowercase` leaves every
/// non-ASCII capital alone. Names derived from a bluebook must come out the same in both runtimes.
pub fn ruby_downcase(text: &str) -> String {
    text.chars().flat_map(char::to_lowercase).collect()
}

/// `Naming.pascal`: snake_case to PascalCase. Each `_`-separated part has its first character
/// upcased with the full Unicode mapping, as `String#upcase` does.
pub fn pascal(text: &str) -> String {
    text.split('_')
        .map(|part| {
            let mut chars = part.chars();
            chars.next().map_or_else(String::new, |first| {
                first.to_uppercase().collect::<String>() + chars.as_str()
            })
        })
        .collect()
}

/// `Naming.plural`: "y" after a consonant becomes "ies", a sibilant takes "es", else "s".
pub fn plural(word: &str) -> String {
    let mut tail = word.chars().rev();
    if tail.next() == Some('y') && tail.next().is_some_and(|c| !"aeiou".contains(c)) {
        return format!("{}ies", &word[..word.len() - 1]);
    }
    if ends_in_sibilant(word) {
        return format!("{word}es");
    }
    format!("{word}s")
}

/// `Naming.singularize`: the crude inverse of `plural` ("ies" to "y", a sibilant's "es" and
/// then a trailing "s" dropped); it only has to find a name someone already wrote.
pub fn singularize(word: &str) -> String {
    let length = word.chars().count();
    if length > 3 {
        if let Some(stem) = word.strip_suffix("ies") {
            return format!("{stem}y");
        }
        // Undo `plural`'s "es" after s/x/z/ch/sh before the bare-"s" rule, so "Boxes" gives
        // "Box" while "Invoices" still gives "Invoice".
        if let Some(stem) = word.strip_suffix("es") {
            if ends_in_sibilant(stem) {
                return stem.to_string();
            }
        }
    }
    if length > 1 {
        if let Some(stem) = word.strip_suffix('s') {
            return stem.to_string();
        }
    }
    word.to_string()
}

/// `/(s|x|z|ch|sh)\z/`
fn ends_in_sibilant(word: &str) -> bool {
    ["s", "x", "z", "ch", "sh"]
        .iter()
        .any(|suffix| word.ends_with(suffix))
}

/// The first `gsub`: `([A-Z]+)([A-Z][a-z])` becomes `\1_\2`.
fn acronym_boundary(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_ascii_uppercase() {
            let mut j = i;
            while j < chars.len() && chars[j].is_ascii_uppercase() {
                j += 1;
            }
            let run_len = j - i;
            if run_len >= 2 && j < chars.len() && chars[j].is_ascii_lowercase() {
                out.extend(&chars[i..j - 1]);
                out.push('_');
                out.push(chars[j - 1]);
                i = j;
                continue;
            }
            out.extend(&chars[i..j]);
            i = j;
            continue;
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

/// The second `gsub`: `([a-z\d])([A-Z])` becomes `\1_\2`, with `\d` ASCII as in Ruby.
fn word_boundary(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::new();
    for (idx, &c) in chars.iter().enumerate() {
        if idx > 0 && c.is_ascii_uppercase() {
            let prev = chars[idx - 1];
            if prev.is_ascii_lowercase() || prev.is_ascii_digit() {
                out.push('_');
            }
        }
        out.push(c);
    }
    out
}
