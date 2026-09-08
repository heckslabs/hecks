//! Source-body slicing + whitespace collapse — mirrors
//! `Hecks::Bluebook::Expression::CanonicalForm`
//! (lib/hecks/bluebook/expression/canonical_form.rb), which itself
//! reads its normalisation rules from
//! lib/hecks/bluebook/expression/projection.json rather than hosting
//! them as a second hand-written table.
//!
//! Used for `given`/`ensures`/`invariant`/`identified_by { }` bodies —
//! these are captured as RAW TEXT and canonicalized, NEVER interpreted.
//! The existing `evaluator.rb`/`resolver.rb`/`expr_emitter.rb`/
//! `rust/src/kernel/expr.rs` pipeline for predicate text is untouched and
//! out of scope for this parser; this module only has to reproduce the
//! byte-for-byte TEXT the Ruby side would capture for the same source
//! span, not understand what the text means.
//!
//! THE TWO RULES ARE HAND-MIRRORED, not generated. Unlike keywords.rs
//! (~230 rows, changes as the language grows), projection.json's own
//! `normalisations` array is two small, stable entries — hand-mirroring
//! is honest here (each rule cites its Ruby source), and this module notes
//! plainly that a THIRD rule landing in projection.json without a matching
//! update here would silently drift; if this table ever needs to grow
//! past "small and stable" it should become generated the same way
//! keywords.rs is, not stay hand-maintained past the point that's safe.

/// Slices the raw source bytes between two byte offsets — the body of a
/// `source`-shaped block (see keywords.rs's `Body` column) exactly as
/// written, before any normalisation. Kept as its own step because a
/// `source` body is captured, not lexed: the shape/word/argument gates
/// never look inside it.
pub fn slice(source: &str, start: usize, end: usize) -> &str {
    &source[start..end]
}

/// `CanonicalForm.apply` — collapse all whitespace runs to a single space,
/// then replace `.length` with `.size` at a word boundary, then trim.
/// Rule order matches projection.json's own `position` column (1, then 2).
/// Both rules run OUTSIDE string literals only — mirroring Ruby's
/// `map_outside_strings` (`canonical_form.rb:71-116`, the M7 fix):
/// quoted runs (either quote character) pass through byte-for-byte, so
/// whitespace inside `"a  b"` survives and `".length"` inside a literal
/// is never folded. This parser was quote-blind here until the `ast`
/// work made the divergence load-bearing (a differently-canonicalised
/// string parses to a different tree).
pub fn apply(source: &str) -> String {
    let collapsed = map_outside_strings(source, collapse_whitespace);
    let replaced = map_outside_strings(&collapsed, |run| replace_word_boundary(run, ".length", ".size"));
    replaced.trim().to_string()
}

/// Splits `text` into quoted and unquoted runs, applies `transform` to
/// the unquoted runs only, and copies quoted runs (including their
/// quotes) through verbatim. A backslash escapes the next character
/// inside a quoted run, exactly as Ruby's scanner treats it.
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

/// `rule.boundary == "word"` — `.length` becomes `.size` only when not
/// immediately followed by another identifier character, mirroring Ruby's
/// `gsub(/#{Regexp.escape(token)}(?![[:alnum:]_])/, replacement)`.
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
        // `lengthy` must not become `sizey` — the boundary check earns its
        // keep exactly here.
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
