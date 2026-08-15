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

/// A CALL ARGUMENT'S OWN Hash/Array/paren literal may span MORE than one
/// physical line — `dispatch`'s own `with:` value, real corpus syntax
/// confirmed by banking.bluebook's `Onboarding` saga:
///
///   dispatch "Banking::Account.Open", with: {
///     customer_id: :customer,
///     number:      :account_number,
///     kind:        { name: "current" },
///     daily_limit: { cents: 0 }
///   }
///
/// No earlier corpus member (pizzas, the framework trio, the grammar
/// chapters) ever wrote a call whose own `(){}[]` don't balance by end of
/// physical line, so `classify`/`split_opener` never needed to look past
/// one line's own text at all. This is a PREPROCESSING pass over the
/// RAW file text, run once before `lines()` — not a change to `lines()`
/// or `classify` themselves — so it has to reproduce the SAME line COUNT
/// the input had (a merged-away physical line becomes an EMPTY output
/// line, never removed outright), or every diagnostic after a merge
/// would report the wrong line number.
///
/// Comments are stripped HERE, independently, per ORIGINAL physical
/// line, before any joining happens — a comment on an interior line of a
/// merge group, left in place, would otherwise swallow every line joined
/// after it once `lines()`'s own (single, whole-merged-line) comment
/// strip ran on the RESULT instead.
///
/// Deliberately NOT aware of `do ... end` nesting at all — `do`/`end`
/// are words, not brackets, so a predicate body spanning many physical
/// lines (`given(...) do ... end`) is completely untouched by this pass
/// (confirmed: every real corpus predicate's own brackets, if it has
/// any, already balance on the one line it's written on); only a call's
/// own trailing `(){}[]` can ever leave depth nonzero at end of line.
pub fn join_continuations(source: &str) -> String {
    let raw_lines: Vec<&str> = source.lines().collect();
    let mut out: Vec<String> = vec![String::new(); raw_lines.len()];
    let mut depth: i32 = 0;
    let mut merge_target: Option<usize> = None;

    for (idx, raw_line) in raw_lines.iter().enumerate() {
        let mut text = strip_comment(raw_line).trim().to_string();

        // BACKSLASH LINE CONTINUATION — Ruby's own trailing `\` (outside
        // any quoted string), used here for adjacent STRING LITERAL
        // concatenation across physical lines:
        //
        //   template: "{name} admits {admits}, which this chapter does " \
        //             "not declare — a closed set is named ..."
        //
        // real corpus syntax (vocabulary.bluebook's own `RefusalTemplate`
        // rows — the wording is long enough several members wrap it).
        // The `\` is stripped here so nothing downstream ever sees it;
        // the two adjacent quoted strings that result are concatenated
        // by `ruby_value::read` (Ruby's own adjacent-literal rule, not
        // anything special about the backslash itself — the backslash's
        // only job is suppressing the newline as a statement end).
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

        // A TRAILING, UNBRACKETED COMMA also continues the logical
        // line — `member refusal: "X", site: "Y",` + `template: "Z"`,
        // real corpus syntax (vocabulary.bluebook's own `RefusalTemplate`
        // rows again): a single bare `member ...` call's own named
        // arguments spill across two physical lines with no enclosing
        // bracket at all for `bracket_delta` to track depth against —
        // Ruby continues a statement across a line ending in a bare
        // comma the same way it does one ending in an open bracket.
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

/// Whether `text`'s scan ends OUTSIDE any quoted string — shared by
/// `ends_with_bare_backslash`/`ends_with_bare_comma` below, the same
/// quote/escape-aware character scan `bracket_delta` already uses for
/// its own bracket-depth tracking, just reporting the quoting state
/// instead of a depth delta.
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

/// A lone trailing `\` outside any quoted string — Ruby's own line
/// continuation escape. See `join_continuations`'s own header for the
/// real corpus shape this exists for.
fn ends_with_bare_backslash(text: &str) -> bool {
    text.ends_with('\\') && ends_outside_quotes(text)
}

/// A lone trailing `,` outside any quoted string, once the line's own
/// bracket depth has already returned to (or stayed at) zero — see
/// `join_continuations`'s own header for the real corpus shape this
/// exists for.
fn ends_with_bare_comma(text: &str) -> bool {
    text.ends_with(',') && ends_outside_quotes(text)
}

/// The NET change in `(){}[]` depth a line of already-comment-stripped
/// text contributes — quote-aware (a bracket character inside a quoted
/// string never counts), the same scanning shape `find_top_level_
/// assignment` already uses elsewhere in this module. Not bracket-TYPE
/// aware (a stray `}` matching an unrelated `[` would still balance) —
/// the same simplification `find_top_level_assignment`'s own depth
/// counter already makes; real bluebook source never actually mismatches
/// bracket types, so this is a legitimate shortcut, not a guess.
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
/// inside a parenthesized argument list, e.g. `where(balance: {gte: 100})`
/// (`where`'s own trailing `{gte: 100}` is a hash LITERAL argument, not a
/// `source`-shaped block; only a `{` at paren-depth zero is even a
/// candidate) — AND not a hash-literal argument written WITHOUT wrapping
/// parens either, real corpus syntax confirmed live:
/// `sets :toppings, append: { name: :topping, amount: :amount }`
/// (pizzas.bluebook) has no parens around its own arguments at all, so
/// paren-depth alone can't rule its trailing `{...}` out — `is_hash_
/// literal_brace` is the second check that does.
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

/// A top-level `{` immediately preceded (skipping whitespace) by `:`,
/// `,`, or `>` is a HASH-LITERAL argument's own opening brace, never a
/// `source`-shaped block opener: a genuine block/predicate-body brace is
/// always either the LAST token of the call (`given("desc") { ... }`,
/// preceded by `)`) or the very first thing after the word itself
/// (`identified_by { ... }`, nothing precedes it at all — `before` is
/// empty). `>` (the second character of a hash-rocket `=>`) joins `:`/`,`
/// for the SAME reason each of them is here: real, confirmed live syntax
/// — `spec/fixtures/hop_chain.bluebook`'s own parenless `where
/// :"engagement.client.status" => { ne: "active" }` — was refused
/// outright without it ("'where' was written with a `{ ... }` block
/// (expected one of: none)"), even though the identical VALUE shape
/// already works fine the moment it sits inside wrapping parens
/// (`where(:"pizza.price_cents.cents" => { lt: :ceiling })`,
/// pizzas.bluebook) — there, `find_top_level_brace`'s own paren-depth
/// tracking already excludes the inner `{` for a different reason (depth
/// 1, not 0) before this character check is ever consulted, so the gap
/// only shows up in the parenless spelling.
fn is_hash_literal_brace(before: &str) -> bool {
    matches!(before.trim_end().chars().last(), Some(':') | Some(',') | Some('>'))
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

/// `Pizzas::Order.persisted_by("PostgresEra")` / `Pizzas::Order.port
/// "PaymentGateway" do` — a HECKSAGON body line addressed to one already-
/// declared aggregate, via Ruby's own `BindingProxy`
/// (`lib/hecksagain/bluebook/dsl/binding_proxy.rb`): `<Domain>::
/// <Aggregate>.<verb>`. Real corpus syntax, confirmed by reading
/// `examples/pizzas/bluebook/pizzas.hecksagon` directly — not the bare
/// `Hecks.hecksagon "Name" do` header form `FILE_RECEIVER_PREFIX` already
/// strips (that's the OUTSIDE of the file; this is legal only inside a
/// Hecksagon body), and not merged into `classify`'s own general shape
/// gate: this receiver-qualified form is legal ONLY inside a Hecksagon
/// body, so `parse::hecksagon` calls this directly rather than every
/// context inheriting a shape it can't actually use.
///
/// Returns `(receiver, rest)` — `receiver` is the WHOLE dotted head
/// (`"Pizzas::Order"`), `rest` is everything after the `.` (never
/// re-parsed here; the caller feeds it back through `classify` as an
/// ordinary call).
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

/// Captures a `do ... end` block's own RAW body text — the SAME
/// `source`-shaped meaning `Opener::BraceBlock`'s own captured `body`
/// already carries for a `{ ... }` spelling of the IDENTICAL semantic
/// block (`identified_by`'s two spellings both declare exactly the same
/// `source` row in syntax.bluebook, `body_gate` above admits both openers
/// for it — see that function's own comment). Starts at `*pos` (already
/// past the opening `do` line, which the caller's own `next_line`/
/// `argument_gate` already consumed and gated), reads raw physical lines
/// — already comment-stripped and per-line-trimmed by `lines()` — up to
/// and including the matching `end`, joining every line but that final
/// `end` with a single space. NEVER gated against `KEYWORDS`, NEVER
/// interpreted — exactly the same "captured as raw text and
/// canonicalized, never interpreted" discipline `given`/`invariant`/a
/// brace-spelled `identified_by { }` already get via `canonical::apply`
/// (the caller's own job, not this function's). Tracks nesting depth
/// TEXTUALLY (a stray `do ... end` written INSIDE the body — not real
/// syntax anywhere in this codebase today — doesn't stop early at its own
/// inner `end`), the same defensive discipline `find_top_level_brace`/
/// `matching_brace_body` already apply to a brace-spelled body.
pub fn capture_do_block_body<'a>(file: &str, lines: &[SourceLine<'a>], pos: &mut usize) -> Result<String, Diagnostic> {
    let mut depth: i32 = 0;
    let mut parts: Vec<&'a str> = Vec::new();

    loop {
        let line = *lines.get(*pos).ok_or_else(|| {
            let last = lines.last().map(|l| l.number).unwrap_or(0);
            Diagnostic::new(file, last, "unexpected end of file — still inside a `do ... end` block".to_string())
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

/// A purely TEXTUAL "does this line open a `do` block" check — deliberately
/// NOT `classify`/`split_opener` (those enforce the closed word-call shape
/// this captured body is explicitly exempt from; raw source text inside a
/// `source`-shaped body can be anything). Mirrors `trailing_do`'s own three
/// shapes (`... do`, bare `do`, `... do |params|`) against a WHOLE line
/// rather than a call's own already-word-stripped `rest`.
fn opens_a_do_block(text: &str) -> bool {
    let trimmed = text.trim_end();
    trimmed == "do" || trimmed.ends_with(" do") || (trimmed.ends_with('|') && trimmed.contains(" do "))
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
    fn strips_an_aggregate_qualified_receiver() {
        assert_eq!(strip_aggregate_receiver("Pizzas::Order.persisted_by(\"Postgres\")"), Some(("Pizzas::Order", "persisted_by(\"Postgres\")")));
        assert_eq!(strip_aggregate_receiver("Pizzas::Order.port \"PaymentGateway\" do"), Some(("Pizzas::Order", "port \"PaymentGateway\" do")));
    }

    #[test]
    fn does_not_strip_a_bare_lowercase_call() {
        assert_eq!(strip_aggregate_receiver("uses_framework \"Governance\""), None);
        assert_eq!(strip_aggregate_receiver("subscribe \"Deposited\""), None);
    }

    #[test]
    fn does_not_strip_end() {
        assert_eq!(strip_aggregate_receiver("end"), None);
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
    fn captures_a_multi_line_do_block_body_as_raw_text() {
        // governance.bluebook's own `RoleAssignment` — multi-path
        // `identified_by do ... end`.
        let source = "identified_by do\n  actor_id.value\n  role_name.value\n  starts_at.value\nend\nattribute :actor_id, IdentityId\n";
        let got = lines(source);
        // got[0] is the `identified_by do` line itself — the caller
        // consumes that via `next_line`/`argument_gate` before calling
        // `capture_do_block_body`, so this test starts at index 1.
        let mut pos = 1usize;
        let body = capture_do_block_body("f.bluebook", &got, &mut pos).unwrap();
        assert_eq!(body, "actor_id.value role_name.value starts_at.value");
        // `*pos` landed past the `end` line, at the next real line.
        assert_eq!(got[pos].text, "attribute :actor_id, IdentityId");
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

    #[test]
    fn joins_a_bare_trailing_comma_across_no_bracket_at_all() {
        // vocabulary.bluebook's own `RefusalTemplate` rows — a `member`
        // call's own named arguments spill across two physical lines
        // with no enclosing bracket for bracket_delta to track.
        let source = "member refusal: \"NotFound\", site: \"creating_no_identity\",\n       template: \"pass {identity}:\"\n";
        let joined = join_continuations(source);
        assert_eq!(joined, "member refusal: \"NotFound\", site: \"creating_no_identity\", template: \"pass {identity}:\"\n");
    }

    #[test]
    fn joins_a_backslash_continued_line_and_strips_the_backslash() {
        // vocabulary.bluebook's own long `RefusalTemplate` wording,
        // wrapped across two physical lines Ruby's own line-continuation
        // escape (adjacent string literals concatenate — see
        // `ruby_value::scan_adjacent_strings`, which is what actually
        // combines the two quoted strings this leaves behind).
        let source = "template: \"a \" \\\n          \"b\"\n";
        let joined = join_continuations(source);
        assert_eq!(joined, "template: \"a \" \"b\"\n");
    }

    #[test]
    fn a_backslash_inside_a_still_open_quoted_string_is_not_a_continuation() {
        // The quote-aware scan must not mistake an ordinary backslash
        // ESCAPE inside a string (`"a\\"`, an escaped backslash, string
        // still open) for the line-continuation marker — `ends_outside_
        // quotes` only fires when the string closed before the trailing
        // `\`, which is not the case here (odd number of trailing
        // backslashes inside an unterminated string).
        assert!(!ends_with_bare_backslash("template: \"a\\"));
    }
}
