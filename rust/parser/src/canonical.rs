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
pub fn apply(source: &str) -> String {
    let collapsed = collapse_whitespace(source);
    let replaced = replace_word_boundary(&collapsed, ".length", ".size");
    replaced.trim().to_string()
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
