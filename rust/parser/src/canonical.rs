//! Source-body slicing and whitespace collapse, mirroring Ruby's `CanonicalForm`.
//! Hand-mirrored from projection.json: a rule there (collapse_whitespace, replace, scale_call) needs a matching rule here.

/// Slices the raw source between two byte offsets, before any normalisation.
pub fn slice(source: &str, start: usize, end: usize) -> &str {
    &source[start..end]
}

/// Canonical text of a captured body: whitespace runs collapse to one space, `.length`
/// becomes `.size`, then trim. Quoted runs pass through untouched, matching Ruby.
pub fn apply(source: &str) -> String {
    let collapsed = map_outside_strings(source, collapse_whitespace);
    let replaced = map_outside_strings(&collapsed, |run| replace_word_boundary(run, ".length", ".size"));
    let scaled = SCALE_CALLS.iter().fold(replaced, |text, (token, seconds)| {
        map_outside_strings(&text, |run| scale_call(run, token, seconds))
    });
    scaled.trim().to_string()
}

/// The `scale_call` rows of projection.json, in position order: (call name, seconds per unit).
const SCALE_CALLS: [(&str, &str); 3] = [("days", "86400"), ("hours", "3600"), ("minutes", "60")];

/// Every normalisation row of projection.json as (strategy, source_token, replacement,
/// boundary, position), in position order; emitted into the IR's expression table.
pub const TABLE: [(&str, &str, &str, &str, &str); 5] = [
    ("collapse_whitespace", "", "", "none", "1"),
    ("replace", ".length", ".size", "word", "2"),
    ("scale_call", "days", "86400", "word", "3"),
    ("scale_call", "hours", "3600", "word", "4"),
    ("scale_call", "minutes", "60", "word", "5"),
];

/// Folds `token(<whole number>)` into the number times `seconds`, as Ruby's `scale_call` does.
/// The name must not follow a word character, digit, underscore or dot; spaces inside the
/// parentheses are allowed; any other argument leaves the call as written.
fn scale_call(text: &str, token: &str, seconds: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        if text[i..].starts_with(token) {
            let preceded = text[..i]
                .chars()
                .next_back()
                .map_or(false, |c| c.is_alphanumeric() || c == '_' || c == '.');
            if !preceded {
                if let Some((digits, len)) = whole_number_call(&text[i + token.len()..]) {
                    out.push_str(&multiply(digits, seconds));
                    i += token.len() + len;
                    continue;
                }
            }
        }
        let ch = text[i..].chars().next().unwrap();
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

/// Matches `(` spaces digits spaces `)` at the start of `rest`; returns the digits and the
/// matched length.
fn whole_number_call(rest: &str) -> Option<(&str, usize)> {
    let inner = rest.strip_prefix('(')?;
    let digits_at = inner.len() - inner.trim_start_matches(char::is_whitespace).len();
    let body = &inner[digits_at..];
    let digit_len = body.bytes().take_while(|b| b.is_ascii_digit()).count();
    if digit_len == 0 {
        return None;
    }
    let tail = &body[digit_len..];
    let close = tail.len() - tail.trim_start_matches(char::is_whitespace).len();
    tail[close..].strip_prefix(')')?;
    Some((&body[..digit_len], 1 + digits_at + digit_len + close + 1))
}

/// Decimal `digits` times the decimal `factor`, as text with no leading zeros (any length).
fn multiply(digits: &str, factor: &str) -> String {
    let factor: u32 = factor.parse().expect("scale factor is a whole number");
    let mut carry = 0u32;
    let mut out: Vec<u8> = Vec::with_capacity(digits.len() + 6);
    for d in digits.bytes().rev() {
        let v = (d - b'0') as u32 * factor + carry;
        out.push(b'0' + (v % 10) as u8);
        carry = v / 10;
    }
    while carry > 0 {
        out.push(b'0' + (carry % 10) as u8);
        carry /= 10;
    }
    while out.len() > 1 && out.last() == Some(&b'0') {
        out.pop();
    }
    out.reverse();
    String::from_utf8(out).unwrap()
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
    fn folds_duration_calls_into_seconds() {
        assert_eq!(apply("days(730)"), "63072000");
        assert_eq!(apply("days( 1 ) + hours(2) + minutes(15)"), "86400 + 7200 + 900");
        assert_eq!(
            apply("x.days(3) workdays(3) days(n) days(1.5)"),
            "x.days(3) workdays(3) days(n) days(1.5)"
        );
        assert_eq!(apply("'days(2)' == days(0)"), "'days(2)' == 0");
    }

    /// Splits JSON text into its string literals, decoding escapes.
    fn json_strings(text: &str) -> Vec<String> {
        let mut out = Vec::new();
        let mut chars = text.chars();
        while let Some(c) = chars.next() {
            if c != '"' {
                continue;
            }
            let mut s = String::new();
            while let Some(c) = chars.next() {
                match c {
                    '"' => break,
                    '\\' => match chars.next().unwrap() {
                        'n' => s.push('\n'),
                        't' => s.push('\t'),
                        'r' => s.push('\r'),
                        'u' => {
                            let hex: String = chars.by_ref().take(4).collect();
                            s.push(char::from_u32(u32::from_str_radix(&hex, 16).unwrap()).unwrap());
                        }
                        other => s.push(other),
                    },
                    c => s.push(c),
                }
            }
            out.push(s);
        }
        out
    }

    #[test]
    fn matches_the_shared_canonical_form_cases() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../spec/fixtures/canonical_form_cases.json");
        let text = std::fs::read_to_string(path).expect("shared cases file");
        let strings = json_strings(&text);
        let start = strings.iter().position(|s| s == "cases").expect("cases key") + 1;
        let rows: Vec<&[String]> = strings[start..].chunks(4).collect();
        assert!(!rows.is_empty());
        for row in rows {
            assert_eq!((row[0].as_str(), row[2].as_str()), ("source", "canonical"));
            assert_eq!(apply(&row[1]), row[3], "source {:?}", row[1]);
        }
    }

    #[test]
    fn slices_the_exact_source_span() {
        let source = "given(\"ok\") { balance >= amount }";
        let start = source.find('{').unwrap();
        let end = source.rfind('}').unwrap() + 1;
        assert_eq!(slice(source, start, end), "{ balance >= amount }");
    }
}
