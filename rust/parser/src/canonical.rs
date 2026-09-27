//! Source-body slicing and whitespace collapse, mirroring Ruby's `CanonicalForm`.
//! Hand-mirrored from projection.json: a third rule there needs a matching rule here.

/// Slices the raw source between two byte offsets, before any normalisation.
pub fn slice(source: &str, start: usize, end: usize) -> &str {
    &source[start..end]
}

/// Canonical text of a captured body: whitespace runs collapse to one space, `.length`
/// becomes `.size`, then trim. Quoted runs pass through untouched, matching Ruby.
pub fn apply(source: &str) -> String {
    let collapsed = map_outside_strings(source, collapse_whitespace);
    let replaced = map_outside_strings(&collapsed, |run| replace_word_boundary(run, ".length", ".size"));
    replaced.trim().to_string()
}

/// Applies `transform` to the unquoted runs of `text` and copies quoted runs verbatim;
/// a backslash escapes the next character inside a quoted run.
fn map_outside_strings(text: &str, transform: impl Fn(&str) -> String) -> String {
    let mut out = String::with_capacity(text.len());
    let mut plain = String::new();
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '"' || ch == '\'' {
            out.push_str(&transform(&plain));
            plain.clear();
            out.push(ch);
            let quote = ch;
            while let Some(inner) = chars.next() {
                out.push(inner);
                if inner == '\\' {
                    if let Some(escaped) = chars.next() {
                        out.push(escaped);
                    }
                    continue;
                }
                if inner == quote {
                    break;
                }
            }
        } else {
            plain.push(ch);
        }
    }
    out.push_str(&transform(&plain));
    out
}

fn collapse_whitespace(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_run = false;
    for ch in text.chars() {
        if ch.is_whitespace() {
            if !in_run {
                out.push(' ');
                in_run = true;
            }
        } else {
            out.push(ch);
            in_run = false;
        }
    }
    out
}

/// Replaces `token` with `replacement` unless another identifier character follows it.
fn replace_word_boundary(text: &str, token: &str, replacement: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if text[i..].starts_with(token) {
            let after = i + token.len();
            let boundary_ok = match text[after..].chars().next() {
                None => true,
                Some(c) => !(c.is_alphanumeric() || c == '_'),
            };
            if boundary_ok {
                out.push_str(replacement);
                i = after;
                continue;
            }
        }
        let ch = text[i..].chars().next().unwrap();
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collapses_runs_of_whitespace() {
        assert_eq!(apply("balance   >=\n  amount"), "balance >= amount");
    }

    #[test]
    fn replaces_length_at_a_word_boundary_only() {
        assert_eq!(apply("items.length"), "items.size");
        // `lengthy` must not become `sizey`.
        assert_eq!(apply("lengthy"), "lengthy");
    }

    #[test]
    fn slices_the_exact_source_span() {
        let source = "given(\"ok\") { balance >= amount }";
        let start = source.find('{').unwrap();
        let end = source.rfind('}').unwrap() + 1;
        assert_eq!(slice(source, start, end), "{ balance >= amount }");
    }
}
