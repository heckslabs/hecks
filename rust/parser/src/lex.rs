//! The lexer — comment/blank-line stripping, and the SHAPE gate (the first
//! of the four parsing gates: shape, word, argument, body — see the crate's
//! module doc in main.rs).
//!
//! A `.bluebook` line must be one of a SMALL FIXED SET of forms: a bare
//! word call (`aggregate "Pizza" do`, `attribute :name, String`, `end`).
//! Bare Ruby expressions, `if`/`unless`/control flow, and local variable
//! assignment are hard errors here — never silently skipped, never
//! interpreted as Ruby. This is deliberate and load-bearing: the DSL *is*
//! real Ruby underneath (`instance_eval`'d against builder objects), but
//! this parser never runs a Ruby interpreter, so it can only ever admit
//! the shapes it explicitly recognizes.

use crate::diag::Diagnostic;

#[derive(Debug, Clone, Copy)]
pub struct SourceLine<'a> {
    pub number: usize,
    pub text: &'a str,
}

/// Comment-stripped, blank-line-free physical lines, each carrying its
/// original (1-based) line number for diagnostics. A `#` starts a comment
/// unless it's inside a quoted string — `description "a # not a comment"`
/// must keep its `#`.
pub fn lines(source: &str) -> Vec<SourceLine<'_>> {
    source
        .lines()
        .enumerate()
        .filter_map(|(idx, raw)| {
            let stripped = strip_comment(raw);
            let trimmed = stripped.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(SourceLine { number: idx + 1, text: trimmed })
            }
        })
        .collect()
}

fn strip_comment(line: &str) -> &str {
    let mut quoting = false;
    let mut escaping = false;
    for (byte_idx, ch) in line.char_indices() {
        if escaping {
            escaping = false;
            continue;
        }
        if quoting && ch == '\\' {
            escaping = true;
            continue;
        }
        if ch == '"' {
            quoting = !quoting;
            continue;
        }
        if ch == '#' && !quoting {
            return &line[..byte_idx];
        }
    }
    line
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Opener {
    None,
    /// `word ... do` / `word ... do |params|` — a multi-line body closed by
    /// a matching `end`, walked line-by-line by the caller (parse/mod.rs)
    /// rather than pre-collected here, since a `keywords`-body block's
    /// content is itself a nested sequence of gated lines, not raw text.
    DoBlock { params: Option<String> },
    /// `word(...) { ... }` — a `source`-shaped body: raw predicate text,
    /// captured and canonicalized (canonical.rs), NEVER interpreted. May
    /// span multiple physical lines; `body` is everything between the
    /// matching braces, exclusive.
    BraceBlock { body: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Call {
    pub word: String,
    /// Raw argument text between the word and the opener, trimmed —
    /// surrounding parens stripped if present and balanced. Never
    /// interpreted here; parse/argument.rs (the argument gate) is what
    /// tokenizes and classifies it.
    pub args: String,
    pub opener: Opener,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LineShape {
    /// `end` — closes the innermost open `do` block.
    End,
    Call(Call),
}

/// RUBY CONTROL-FLOW / DECLARATION KEYWORDS this DSL never admits as a
/// bare leading word — a real hand-written `if`/`case`/`def` in a
/// `.bluebook` file is refused here rather than silently accepted as an
/// unrecognized "word" (which would instead hit the word gate and produce
/// a less specific error). Named explicitly so the shape-gate diagnostic
/// can say what's actually wrong.
const FORBIDDEN_LEADING_WORDS: &[&str] = &[
    "if", "unless", "while", "until", "case", "begin", "def", "class", "module", "return", "next",
    "break", "redo", "retry", "yield", "lambda", "proc", "for", "loop",
];

/// EVERY REAL FILE'S OWN TOP LINE — confirmed by reading the actual
/// corpus, not assumed from the plan: `Hecks.bluebook "Pizzas" do`,
/// `Hecks.hecksagon`, `Hecks.bluebook "World"` (world.bluebook itself),
/// never the bare `bluebook "Name" do` this crate's own doc comments
/// first assumed. `spec/syntax_conformance_spec.rb`'s own comment says
/// why: "`File` is the outside of every body — `Hecks.bluebook` is
/// reached through the `Hecks` receiver rather than an enclosing
/// builder." Every OTHER line is `instance_eval`'d against a builder and
/// so is never receiver-qualified — this prefix is stripped ONLY here,
/// not generally, or a nested `Hecks.something` (which cannot legally
/// occur) would be silently tolerated instead of refused.
const FILE_RECEIVER_PREFIX: &str = "Hecks.";

/// The shape gate. Classifies one already comment-stripped, trimmed,
/// non-blank line — or refuses it outright as a diagnostic naming what
/// shape it actually needs to be.
pub fn classify<'a>(file: &str, line: &SourceLine<'a>) -> Result<LineShape, Diagnostic> {
    let text = line.text.strip_prefix(FILE_RECEIVER_PREFIX).unwrap_or(line.text);

    if text == "end" {
        return Ok(LineShape::End);
    }

    let word_end = leading_identifier_end(text);
    if word_end == 0 {
        return Err(Diagnostic::new(
            file,
            line.number,
            format!("'{text}' is not a word call — every line must be a keyword call or `end`"),
        ));
    }
    let word = &text[..word_end];

    if FORBIDDEN_LEADING_WORDS.contains(&word) {
        return Err(Diagnostic::new(
            file,
            line.number,
            format!(
                "'{word}' is a bare Ruby control-flow/declaration form, which this parser never \
                 interprets — a bluebook may only use keyword calls this language declares"
            ),
        ));
    }

    let rest = text[word_end..].trim_start();

    if let Some(top_level_eq) = find_top_level_assignment(rest) {
        return Err(Diagnostic::new(
            file,
            line.number,
            format!(
                "'{}' looks like a local variable assignment at byte {top_level_eq} — this \
                 parser never interprets bare Ruby expressions or assignment",
                text
            ),
        ));
    }

    let (args, opener) = split_opener(rest);
    let args = strip_balanced_parens(args.trim());

    Ok(LineShape::Call(Call { word: word.to_string(), args: args.to_string(), opener }))
}

fn leading_identifier_end(text: &str) -> usize {
    let mut end = 0;
    for (idx, ch) in text.char_indices() {
        if idx == 0 {
            if ch.is_ascii_alphabetic() || ch == '_' {
                end = idx + ch.len_utf8();
                continue;
            } else {
                return 0;
            }
        }
        if ch.is_ascii_alphanumeric() || ch == '_' {
            end = idx + ch.len_utf8();
        } else {
            break;
        }
    }
    end
}

/// A top-level (not inside quotes/braces/brackets/parens) bare `=` that
/// isn't part of a wider operator (`==`, `!=`, `<=`, `>=`, `=>`, `=~`) or a
/// `+=`/`-=`-style compound assignment, and isn't a hash-rocket. Returns
/// the byte offset of the first one found, if any.
fn find_top_level_assignment(text: &str) -> Option<usize> {
    let bytes = text.as_bytes();
    let mut depth: i32 = 0;
    let mut quoting = false;
    let mut escaping = false;

    for (idx, ch) in text.char_indices() {
        if escaping {
            escaping = false;
            continue;
        }
        if quoting && ch == '\\' {
            escaping = true;
            continue;
        }
        if ch == '"' {
            quoting = !quoting;
            continue;
        }
        if quoting {
            continue;
        }
        match ch {
            '{' | '[' | '(' => depth += 1,
            '}' | ']' | ')' => depth -= 1,
            '=' if depth == 0 => {
                let prev = if idx == 0 { None } else { Some(bytes[idx - 1] as char) };
                let next = text[idx + 1..].chars().next();
                let is_wide_operator = matches!(prev, Some('=' | '!' | '<' | '>' | '+' | '-' | '*' | '/' | '~'))
                    || matches!(next, Some('=' | '~' | '>'));
                if !is_wide_operator {
                    return Some(idx);
                }
            }
            _ => {}
        }
    }
    None
}

/// Splits the tail of a call line into `(args_text, opener)` — detects a
/// trailing `do`/`do |params|`, a top-level `{ ... }` (captured verbatim,
/// even if it doesn't balance on this one line — `Opener::None` covers
/// "no opener at all").
fn split_opener(rest: &str) -> (String, Opener) {
    if let Some((before, params)) = trailing_do(rest) {
        return (before.to_string(), Opener::DoBlock { params });
    }

    if let Some(brace_start) = find_top_level_brace(rest) {
        let (before, brace_and_after) = rest.split_at(brace_start);
        if let Some((body, _after)) = matching_brace_body(brace_and_after) {
            return (before.to_string(), Opener::BraceBlock { body });
        }
        // Unbalanced on this physical line — a source body that wraps
        // across lines. Callers that need to keep reading do so; Stage 1's
        // stub handlers don't attempt multi-line brace assembly (named as
        // a real, tracked gap below rather than guessed at).
        return (before.to_string(), Opener::BraceBlock { body: brace_and_after.to_string() });
    }

    (rest.to_string(), Opener::None)
}

fn trailing_do(rest: &str) -> Option<(&str, Option<String>)> {
    let trimmed = rest.trim_end();
    if let Some(before) = trimmed.strip_suffix(" do") {
        return Some((before, None));
    }
    if trimmed.ends_with('|') {
        // `do |params|` — find the matching opening `|` and the `do`
        // immediately before it.
        let without_trailing_pipe = &trimmed[..trimmed.len() - 1];
        if let Some(open_pipe) = without_trailing_pipe.rfind('|') {
            let params = &without_trailing_pipe[open_pipe + 1..];
            let before_pipe = trimmed[..open_pipe].trim_end();
            if let Some(before) = before_pipe.strip_suffix(" do") {
                return Some((before, Some(params.trim().to_string())));
            }
        }
    }
    if trimmed == "do" {
        return Some(("", None));
    }
    None
}

/// The first `{` that is a genuine SOURCE-BODY opener — not one buried
/// inside a parenthesized argument list, e.g. `where(balance: {gte: 100})`.
/// `where`'s own trailing `{gte: 100}` is a hash LITERAL argument, not a
/// `source`-shaped block; only a `{` at paren-depth zero can be one.
fn find_top_level_brace(text: &str) -> Option<usize> {
    let mut quoting = false;
    let mut escaping = false;
    let mut paren_depth: i32 = 0;
    for (idx, ch) in text.char_indices() {
        if escaping {
            escaping = false;
            continue;
        }
        if quoting && ch == '\\' {
            escaping = true;
            continue;
        }
        if ch == '"' {
            quoting = !quoting;
            continue;
        }
        if quoting {
            continue;
        }
        match ch {
            '(' => paren_depth += 1,
            ')' => paren_depth -= 1,
            '{' if paren_depth == 0 => return Some(idx),
            _ => {}
        }
    }
    None
}

/// Given text starting at a top-level `{`, returns `(body, rest_after)`
/// with `body` being everything strictly between the matching braces —
/// `None` if this physical line doesn't balance.
fn matching_brace_body(text: &str) -> Option<(String, &str)> {
    let mut depth: i32 = 0;
    let mut quoting = false;
    let mut escaping = false;
    let mut start_byte = None;

    for (idx, ch) in text.char_indices() {
        if escaping {
            escaping = false;
            continue;
        }
        if quoting && ch == '\\' {
            escaping = true;
            continue;
        }
        if ch == '"' {
            quoting = !quoting;
            continue;
        }
        if quoting {
            continue;
        }
        if ch == '{' {
            if depth == 0 {
                start_byte = Some(idx + 1);
            }
            depth += 1;
        } else if ch == '}' {
            depth -= 1;
            if depth == 0 {
                let start = start_byte?;
                let body = text[start..idx].trim().to_string();
                let after = &text[idx + 1..];
                return Some((body, after));
            }
        }
    }
    None
}

fn strip_balanced_parens(text: &str) -> &str {
    if text.starts_with('(') && text.ends_with(')') && text.len() >= 2 {
        let inner = &text[1..text.len() - 1];
        // Only strip when the parens actually wrap the whole thing —
        // depth never touches zero before the very last character.
        let mut depth = 0i32;
        let mut quoting = false;
        let mut escaping = false;
        for (idx, ch) in inner.char_indices() {
            if escaping {
                escaping = false;
                continue;
            }
            if quoting && ch == '\\' {
                escaping = true;
                continue;
            }
            if ch == '"' {
                quoting = !quoting;
                continue;
            }
            if quoting {
                continue;
            }
            match ch {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth < 0 {
                        return text; // closed early — the outer parens don't actually wrap it all
                    }
                }
                _ => {}
            }
            let _ = idx;
        }
        return inner.trim();
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_comments_and_blanks() {
        let source = "aggregate \"Pizza\" do # a comment\n\n  attribute :name, String\nend\n";
        let got = lines(source);
        assert_eq!(got.len(), 3);
        assert_eq!(got[0].text, "aggregate \"Pizza\" do");
        assert_eq!(got[0].number, 1);
        assert_eq!(got[1].text, "attribute :name, String");
        assert_eq!(got[1].number, 3);
        assert_eq!(got[2].text, "end");
    }

    #[test]
    fn strips_the_hecks_receiver_prefix_at_the_top_of_a_file() {
        // Confirmed against the real corpus, not assumed: every actual
        // file (examples/pizzas/bluebook/pizzas.bluebook,
        // lib/hecksagain/language/bluebook/*.bluebook, ...) opens with
        // `Hecks.bluebook "Name" do`, never a bare `bluebook "Name" do`.
        let line = SourceLine { number: 1, text: "Hecks.bluebook \"Pizzas\" do" };
        let shape = classify("f.bluebook", &line).unwrap();
        assert_eq!(
            shape,
            LineShape::Call(Call {
                word: "bluebook".to_string(),
                args: "\"Pizzas\"".to_string(),
                opener: Opener::DoBlock { params: None }
            })
        );
    }

    #[test]
    fn keeps_a_hash_inside_a_quoted_string() {
        let source = "description \"a # not a comment\"\n";
        let got = lines(source);
        assert_eq!(got[0].text, "description \"a # not a comment\"");
    }

    #[test]
    fn classifies_a_plain_call() {
        let line = SourceLine { number: 1, text: "attribute :name, String" };
        let shape = classify("f.bluebook", &line).unwrap();
        assert_eq!(
            shape,
            LineShape::Call(Call {
                word: "attribute".to_string(),
                args: ":name, String".to_string(),
                opener: Opener::None
            })
        );
    }

    #[test]
    fn classifies_a_do_block_opener() {
        let line = SourceLine { number: 1, text: "aggregate \"Pizza\" do" };
        let shape = classify("f.bluebook", &line).unwrap();
        assert_eq!(
            shape,
            LineShape::Call(Call {
                word: "aggregate".to_string(),
                args: "\"Pizza\"".to_string(),
                opener: Opener::DoBlock { params: None }
            })
        );
    }

    #[test]
    fn classifies_a_do_block_with_params() {
        let line = SourceLine { number: 1, text: "on \"Deposited\" do |event|" };
        let shape = classify("f.bluebook", &line).unwrap();
        assert_eq!(
            shape,
            LineShape::Call(Call {
                word: "on".to_string(),
                args: "\"Deposited\"".to_string(),
                opener: Opener::DoBlock { params: Some("event".to_string()) }
            })
        );
    }

    #[test]
    fn classifies_a_brace_source_body() {
        let line = SourceLine { number: 1, text: "identified_by { name.value }" };
        let shape = classify("f.bluebook", &line).unwrap();
        assert_eq!(
            shape,
            LineShape::Call(Call {
                word: "identified_by".to_string(),
                args: "".to_string(),
                opener: Opener::BraceBlock { body: "name.value".to_string() }
            })
        );
    }

    #[test]
    fn classifies_end() {
        let line = SourceLine { number: 1, text: "end" };
        assert_eq!(classify("f.bluebook", &line).unwrap(), LineShape::End);
    }

    #[test]
    fn refuses_bare_if() {
        let line = SourceLine { number: 1, text: "if amount > 0" };
        let err = classify("f.bluebook", &line).unwrap_err();
        assert!(err.message.contains("if"));
    }

    #[test]
    fn refuses_local_assignment() {
        let line = SourceLine { number: 1, text: "x = 1" };
        let err = classify("f.bluebook", &line).unwrap_err();
        assert!(err.message.contains("assignment"));
    }

    #[test]
    fn refuses_a_line_that_is_not_a_word_call() {
        let line = SourceLine { number: 1, text: "\"just a string\"" };
        assert!(classify("f.bluebook", &line).is_err());
    }

    #[test]
    fn allows_a_hash_rocket_and_wide_operators_without_flagging_assignment() {
        // not currently written anywhere in this DSL, but `==`/`>=` inside
        // a captured source body must never be misread as `=`.
        let line = SourceLine { number: 1, text: "given(\"ok\") { balance >= amount }" };
        assert!(classify("f.bluebook", &line).is_ok());
    }

    #[test]
    fn does_not_mistake_a_hash_literal_argument_for_a_source_block() {
        // `where(balance: {gte: 100}, status: "open")` — the `{gte: 100}`
        // is a hash-literal ARGUMENT, not a `source`-shaped `{ ... }`
        // block; only a brace outside every enclosing paren counts.
        let line = SourceLine { number: 1, text: "where(balance: {gte: 100}, status: \"open\")" };
        let shape = classify("f.bluebook", &line).unwrap();
        match shape {
            LineShape::Call(call) => {
                assert_eq!(call.opener, Opener::None);
                assert_eq!(call.args, "balance: {gte: 100}, status: \"open\"");
            }
            _ => panic!("expected a call"),
        }
    }

    #[test]
    fn strips_wrapping_parens_from_arguments() {
        let line = SourceLine { number: 1, text: "bluebook(\"Pizzas\", version: \"1\") do" };
        let shape = classify("f.bluebook", &line).unwrap();
        match shape {
            LineShape::Call(call) => assert_eq!(call.args, "\"Pizzas\", version: \"1\""),
            _ => panic!("expected a call"),
        }
    }
}
