//! How an author's words become the names the IR uses, and back for messages.

/// `published on` -> `published_on`.
pub fn snake(words: &str) -> String {
    words
        .split_whitespace()
        .map(str::to_lowercase)
        .collect::<Vec<_>>()
        .join("_")
}

/// `page slug` -> `PageSlug`; a word keeps the capitals it was written with after its first letter.
pub fn camel(words: &str) -> String {
    words
        .split_whitespace()
        .map(|word| {
            let mut chars = word.chars();
            chars.next().map_or_else(String::new, |first| {
                first.to_uppercase().collect::<String>() + chars.as_str()
            })
        })
        .collect()
}

/// `PageSlug` -> `page slug`, `published_on` -> `published on`, for naming things in messages.
pub fn spoken(name: &str) -> String {
    let mut out = String::new();
    for c in name.chars() {
        if c == '_' {
            out.push(' ');
        } else if c.is_uppercase() {
            if !out.is_empty() && !out.ends_with(' ') {
                out.push(' ');
            }
            out.extend(c.to_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}

/// The scalar a plain-English type names, if it names one.
pub fn scalar(words: &str) -> Option<&'static str> {
    match words.to_lowercase().as_str() {
        "text" => Some("String"),
        "whole number" => Some("Integer"),
        "decimal number" => Some("Float"),
        _ => None,
    }
}

/// The scalar types, as an author says them.
pub const SCALARS: &str = "text, whole number, decimal number";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_convert_both_ways() {
        assert_eq!(snake("Published On"), "published_on");
        assert_eq!(camel("page slug"), "PageSlug");
        assert_eq!(spoken("PublishedOn"), "published on");
        assert_eq!(spoken("customer_name"), "customer name");
    }
}
