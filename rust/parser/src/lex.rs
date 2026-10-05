//! The lexer: strips comments and blank lines, then applies the shape gate.
//! Bare Ruby expressions, control flow and assignment are refused, never interpreted.

use crate::diag::Diagnostic;

#[derive(Debug, Clone, Copy)]
pub struct SourceLine<'a> {
    pub number: usize,
    pub text: &'a str,
}

/// Comment-stripped, blank-free lines with 1-based numbers; a `#` inside a string is kept.
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
                Some(SourceLine {
                    number: idx + 1,
                    text: trimmed,
                })
            }
        })
        .collect()
}

/// Joins lines continued by open brackets, a trailing `\`, or a trailing `,`.
///
/// Keeps the input's line count (merged-away lines become empty) so diagnostics stay accurate.
/// Comments are stripped before joining, or one would swallow the lines merged after it.
pub fn join_continuations(source: &str) -> String {
    let raw_lines: Vec<&str> = source.lines().collect();
    let mut out: Vec<String> = vec![String::new(); raw_lines.len()];
    let mut depth: i32 = 0;
    let mut merge_target: Option<usize> = None;

    for (idx, raw_line) in raw_lines.iter().enumerate() {
        let mut text = strip_comment(raw_line).trim().to_string();

        // A trailing `\` joins adjacent string literals; `ruby_value::read` concatenates them.
        let backslash_continues = ends_with_bare_backslash(&text);
        if backslash_continues {
            text = text[..text.len() - 1].trim_end().to_string();
        }

        match merge_target {
            Some(target) if target != idx => {
                if !text.is_empty() {
                    if !out[target].is_empty() {
                        out[target].push(' ');
                    }
                    out[target].push_str(&text);
                }
            }
            _ => {
                out[idx].push_str(&text);
                merge_target = Some(idx);
            }
        }

        depth += bracket_delta(&text);

        // A trailing bare comma continues the statement, as in Ruby.
        let comma_continues = depth <= 0 && ends_with_bare_comma(&text);

        if depth <= 0 {
            depth = 0;
            if !comma_continues && !backslash_continues {
                merge_target = None;
            }
        }
    }

    out.join("\n")
}

fn ends_outside_quotes(text: &str) -> bool {
    let mut quoting = false;
    let mut escaping = false;
    for ch in text.chars() {
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
    }
    !quoting
}

fn ends_with_bare_backslash(text: &str) -> bool {
    text.ends_with('\\') && ends_outside_quotes(text)
}

fn ends_with_bare_comma(text: &str) -> bool {
    text.ends_with(',') && ends_outside_quotes(text)
}

/// Not bracket-type aware: mismatched bracket types never occur in real source.
fn bracket_delta(text: &str) -> i32 {
    let mut depth = 0i32;
    let mut quoting = false;
    let mut escaping = false;
    for ch in text.chars() {
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
            '(' | '{' | '[' => depth += 1,
            ')' | '}' | ']' => depth -= 1,
            _ => {}
        }
    }
    depth
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
    DoBlock {
        params: Option<String>,
    },
    BraceBlock {
        body: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Call {
    pub word: String,
    /// Raw text between the word and the opener; the argument gate tokenizes it.
    pub args: String,
    pub opener: Opener,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LineShape {
    End,
    Call(Call),
}

/// Ruby keywords refused up front so the diagnostic names the real problem.
const FORBIDDEN_LEADING_WORDS: &[&str] = &[
    "if", "unless", "while", "until", "case", "begin", "def", "class", "module", "return", "next",
    "break", "redo", "retry", "yield", "lambda", "proc", "for", "loop",
];

/// Only a file's top line is receiver-qualified; a nested `Hecks.x` must stay an error.
const FILE_RECEIVER_PREFIX: &str = "Hecks.";

pub fn classify<'a>(file: &str, line: &SourceLine<'a>) -> Result<LineShape, Diagnostic> {
    let text = line
        .text
        .strip_prefix(FILE_RECEIVER_PREFIX)
        .unwrap_or(line.text);

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

    Ok(LineShape::Call(Call {
        word: word.to_string(),
        args: args.to_string(),
        opener,
    }))
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
                let prev = if idx == 0 {
                    None
                } else {
                    Some(bytes[idx - 1] as char)
                };
                let next = text[idx + 1..].chars().next();
                let is_wide_operator = matches!(
                    prev,
                    Some('=' | '!' | '<' | '>' | '+' | '-' | '*' | '/' | '~')
                ) || matches!(next, Some('=' | '~' | '>'));
                if !is_wide_operator {
                    return Some(idx);
                }
            }
            _ => {}
        }
    }
    None
}

fn split_opener(rest: &str) -> (String, Opener) {
    if let Some((before, params)) = trailing_do(rest) {
        return (before.to_string(), Opener::DoBlock { params });
    }

    if let Some(brace_start) = find_top_level_brace(rest) {
        let (before, brace_and_after) = rest.split_at(brace_start);
        if let Some((body, _after)) = matching_brace_body(brace_and_after) {
            return (before.to_string(), Opener::BraceBlock { body });
        }
        // Unbalanced on this line: the body wraps across lines, so keep the whole tail.
        return (
            before.to_string(),
            Opener::BraceBlock {
                body: brace_and_after.to_string(),
            },
        );
    }

    (rest.to_string(), Opener::None)
}

fn trailing_do(rest: &str) -> Option<(&str, Option<String>)> {
    let trimmed = rest.trim_end();
    if let Some(before) = trimmed.strip_suffix(" do") {
        return Some((before, None));
    }
    if trimmed.ends_with('|') {
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

/// A `{` inside parens or written as a hash literal argument is not a source-body opener.
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
            '{' if paren_depth == 0 => {
                if is_hash_literal_brace(&text[..idx]) {
                    continue;
                }
                return Some(idx);
            }
            _ => {}
        }
    }
    None
}

/// A `{` after `:`, `,` or `>` opens a hash literal; `>` covers a parenless `:k => { ... }`.
fn is_hash_literal_brace(before: &str) -> bool {
    matches!(
        before.trim_end().chars().last(),
        Some(':') | Some(',') | Some('>')
    )
}

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

/// Splits `Pizzas::Order.port "X" do` into receiver and rest; legal only in a hecksagon body,
/// so it stays out of `classify`.
pub fn strip_aggregate_receiver(text: &str) -> Option<(&str, &str)> {
    let bytes = text.as_bytes();
    if bytes.is_empty() || !bytes[0].is_ascii_uppercase() {
        return None;
    }

    let mut i = 0;
    loop {
        let start = i;
        while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
            i += 1;
        }
        if i == start || !bytes[start].is_ascii_uppercase() {
            return None;
        }
        if text[i..].starts_with("::") {
            i += 2;
            continue;
        }
        break;
    }

    let rest = text[i..].strip_prefix('.')?;
    if rest.is_empty() {
        return None;
    }
    Some((&text[..i], rest))
}

/// Captures a `do ... end` body as raw space-joined text, tracking nested `do` blocks textually.
pub fn capture_do_block_body<'a>(
    file: &str,
    lines: &[SourceLine<'a>],
    pos: &mut usize,
) -> Result<String, Diagnostic> {
    let mut depth: i32 = 0;
    let mut parts: Vec<&'a str> = Vec::new();

    loop {
        let line = *lines.get(*pos).ok_or_else(|| {
            let last = lines.last().map(|l| l.number).unwrap_or(0);
            Diagnostic::new(
                file,
                last,
                "unexpected end of file — still inside a `do ... end` block".to_string(),
            )
        })?;
        *pos += 1;

        if line.text == "end" {
            if depth == 0 {
                return Ok(parts.join(" "));
            }
            depth -= 1;
            parts.push(line.text);
            continue;
        }
        if opens_a_do_block(line.text) {
            depth += 1;
        }
        parts.push(line.text);
    }
}

/// Textual check, not `classify`: raw source bodies are exempt from the word-call shape.
fn opens_a_do_block(text: &str) -> bool {
    let trimmed = text.trim_end();
    trimmed == "do"
        || trimmed.ends_with(" do")
        || (trimmed.ends_with('|') && trimmed.contains(" do "))
}

fn strip_balanced_parens(text: &str) -> &str {
    if text.starts_with('(') && text.ends_with(')') && text.len() >= 2 {
        let inner = &text[1..text.len() - 1];
        // Strip only when the parens wrap the whole text.
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
                        return text;
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
    fn does_not_strip_a_bare_lowercase_call() {
        assert_eq!(
            strip_aggregate_receiver("attaches \"Governance\""),
            None
        );
        assert_eq!(strip_aggregate_receiver("subscribe \"Deposited\""), None);
    }

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
    fn classifies_a_do_block_with_params() {
        let line = SourceLine {
            number: 1,
            text: "on \"Deposited\" do |event|",
        };
        let shape = classify("f.bluebook", &line).unwrap();
        assert_eq!(
            shape,
            LineShape::Call(Call {
                word: "on".to_string(),
                args: "\"Deposited\"".to_string(),
                opener: Opener::DoBlock {
                    params: Some("event".to_string())
                }
            })
        );
    }

    #[test]
    fn classifies_a_brace_source_body() {
        let line = SourceLine {
            number: 1,
            text: "identified_by { name.value }",
        };
        let shape = classify("f.bluebook", &line).unwrap();
        assert_eq!(
            shape,
            LineShape::Call(Call {
                word: "identified_by".to_string(),
                args: "".to_string(),
                opener: Opener::BraceBlock {
                    body: "name.value".to_string()
                }
            })
        );
    }

    #[test]
    fn captures_a_multi_line_do_block_body_as_raw_text() {
        // governance.bluebook's `RoleAssignment`: multi-path `identified_by do ... end`.
        let source = "identified_by do\n  actor_id.value\n  role_name.value\n  starts_at.value\nend\nattribute :actor_id, IdentityId\n";
        let got = lines(source);
        // got[0] is the `do` line the caller already consumed, so start at index 1.
        let mut pos = 1usize;
        let body = capture_do_block_body("f.bluebook", &got, &mut pos).unwrap();
        assert_eq!(body, "actor_id.value role_name.value starts_at.value");
        assert_eq!(got[pos].text, "attribute :actor_id, IdentityId");
    }

    #[test]
    fn refuses_local_assignment() {
        let line = SourceLine {
            number: 1,
            text: "x = 1",
        };
        let err = classify("f.bluebook", &line).unwrap_err();
        assert!(err.message.contains("assignment"));
    }

    #[test]
    fn refuses_a_line_that_is_not_a_word_call() {
        let line = SourceLine {
            number: 1,
            text: "\"just a string\"",
        };
        assert!(classify("f.bluebook", &line).is_err());
    }

    #[test]
    fn a_backslash_inside_a_still_open_quoted_string_is_not_a_continuation() {
        // An escaped backslash inside a still-open string is not a line continuation.
        assert!(!ends_with_bare_backslash("template: \"a\\"));
    }
}
