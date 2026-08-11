//! The word, argument, and body gates — plus the recursive body-walker
//! that wires all four gates (shape lives in lex.rs) together for real,
//! even though every per-construct module this dispatches to
//! (aggregate.rs, entity.rs, ...) stubs out with `not_yet_implemented`
//! before building any IR. See this crate's main.rs module doc for the
//! full four-gate framing.
//!
//! STAGE 1'S ACTUAL BEHAVIOR: every line, at every nesting depth, is
//! gated for real — shape (lex.rs), word (this file's `word_gate`), body
//! (`body_gate`), argument (`argument_gate`). A line that opens a `do`
//! block recurses into its own `inner` context and keeps gating. The walk
//! only ever stops for one of two reasons: (1) a genuine grammar
//! violation — any gate refuses — which is a real parse error, or (2) a
//! line that fully passes every gate but names a construct this parser
//! doesn't build yet, which is `Diagnostic::not_yet_implemented`. Nothing
//! is ever silently accepted or silently skipped — the "no lenient mode"
//! invariant holds at every depth, not just the outermost line.

pub mod aggregate;
pub mod chapter;
pub mod command;
pub mod domain_port;
pub mod entity;
pub mod file;
pub mod hecksagon;
pub mod lifecycle;
pub mod policy;
pub mod process_manager;
pub mod query;
pub mod read_model;
pub mod value_object;

use crate::diag::{Diagnostic, ParseResult};
use crate::keywords::{self, ArgumentRow, KeywordRow};
use crate::lex::{self, Call, LineShape, Opener, SourceLine};
use crate::ruby_value;

/// THE WORD GATE. Every live `KeywordRow` for `(word, context)` — zero
/// rows is a hard error naming the legal alternatives, exactly the
/// diagnostic shape the plan calls for ("a diagnostic naming legal
/// alternatives when it doesn't [hit a row]").
pub fn word_gate<'a>(
    file: &str,
    word: &str,
    context: &'static str,
    line: usize,
) -> ParseResult<Vec<&'a KeywordRow>> {
    let candidates: Vec<&KeywordRow> =
        keywords::KEYWORDS.iter().filter(|k| k.live() && k.word == word && k.context == context).collect();

    if candidates.is_empty() {
        let mut legal: Vec<String> = keywords::KEYWORDS
            .iter()
            .filter(|k| k.live() && k.context == context)
            .map(|k| k.word.to_string())
            .collect();
        legal.sort();
        legal.dedup();
        return Err(Diagnostic::new(file, line, format!("'{word}' is not a word {context} admits")).with_expected(legal));
    }

    Ok(candidates)
}

/// THE BODY GATE. `none`/`keywords`/`source`/`rows` must match what
/// actually follows — picks, among the word-gated candidate rows, the one
/// whose declared `body` is compatible with the `Opener` the lexer
/// actually found. `identified_by` is the standing example of why this is
/// its own gate and not folded into the word gate: the SAME word admits a
/// `source` row (`identified_by { name.value }`) and `none` rows
/// (`identified_by :name`, `identified_by PizzaName, as: :name`) in the
/// same context, and only the body that actually follows disambiguates
/// which was written.
pub fn body_gate<'a>(
    file: &str,
    candidates: &[&'a KeywordRow],
    opener: &Opener,
    line: usize,
    word: &str,
) -> ParseResult<&'a KeywordRow> {
    let compatible: fn(&str) -> bool = match opener {
        Opener::None => |body| body == "none",
        Opener::DoBlock { .. } => |body| body == "keywords" || body == "rows",
        Opener::BraceBlock { .. } => |body| body == "source",
    };

    if let Some(row) = candidates.iter().find(|row| compatible(row.body)) {
        return Ok(row);
    }

    let legal: Vec<String> = candidates.iter().map(|row| row.body.to_string()).collect();
    let found = match opener {
        Opener::None => "no body",
        Opener::DoBlock { .. } => "a `do ... end` block",
        Opener::BraceBlock { .. } => "a `{ ... }` block",
    };
    Err(Diagnostic::new(file, line, format!("'{word}' was written with {found}")).with_expected(legal))
}

fn kind_matches(declared: &str, actual: &str) -> bool {
    if declared == actual {
        return true;
    }
    // `literal` is the WIDEST kind — a default written so its type
    // survives (`0` rather than `"0"`) — see syntax.bluebook's own
    // comment on ArgumentKind. Accepts anything that isn't already a
    // structural (list/pairs/constant) shape.
    declared == "literal" && matches!(actual, "symbol" | "text" | "number" | "flag")
}

fn classify_lexical_kind(token: &str) -> &'static str {
    let t = token.trim();
    if t.starts_with(':') && t.len() > 1 {
        return "symbol";
    }
    if t.len() >= 2 && t.starts_with('"') && t.ends_with('"') {
        return "text";
    }
    if t == "true" || t == "false" {
        return "flag";
    }
    if t == "nil" {
        return "literal";
    }
    if is_number_token(t) {
        return "number";
    }
    if t.starts_with('[') && t.ends_with(']') {
        return "list";
    }
    if t.starts_with('{') && t.ends_with('}') {
        return "pairs";
    }
    if t.chars().next().map(|c| c.is_ascii_uppercase()).unwrap_or(false) {
        return "constant";
    }
    // Conservative fallback — an unquoted bare word this classifier
    // doesn't have a sharper answer for. Nothing downstream in Stage 1
    // depends on this being exactly right; Stage 2's real argument
    // construction is where this gets exercised against real corpus text.
    "text"
}

fn is_number_token(t: &str) -> bool {
    let body = t.strip_prefix('-').unwrap_or(t);
    if body.is_empty() {
        return false;
    }
    let mut seen_dot = false;
    for ch in body.chars() {
        if ch == '.' && !seen_dot {
            seen_dot = true;
            continue;
        }
        if !ch.is_ascii_digit() {
            return false;
        }
    }
    true
}

/// A segment split at the top level of an argument list is NAMED when it
/// spells `identifier: value` (Ruby's keyword-argument convention this
/// DSL writes throughout — `as: :name`, `optional: true`). Distinguished
/// from a bare positional symbol (`:eq`, leading colon) by requiring the
/// colon to trail the identifier rather than lead it, and from a `::`
/// namespace separator by requiring exactly one colon.
fn as_named(segment: &str) -> Option<(&str, &str)> {
    let bytes = segment.as_bytes();
    if bytes.is_empty() || !(bytes[0].is_ascii_alphabetic() || bytes[0] == b'_') {
        return None;
    }
    let mut i = 1;
    while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
        i += 1;
    }
    if i < bytes.len() && bytes[i] == b':' && bytes.get(i + 1) != Some(&b':') {
        let name = &segment[..i];
        let value = segment[i + 1..].trim_start();
        return Some((name, value));
    }
    None
}

#[derive(Debug, Clone, Default)]
pub struct ArgumentGateResult {
    pub positional: Vec<(usize, String)>,
    pub named: Vec<(String, String)>,
}

/// THE ARGUMENT GATE. Positional/named count and lexical kind must match
/// the declared `ArgumentRow`s for `(word, context)` — joined by
/// `(word, context)` alone (never by which `KeywordRow` the body gate
/// picked), matching syntax.bluebook's own comment on why `identified_by`
/// declares argument rows that "belong to both rows" of that word.
pub fn argument_gate(
    file: &str,
    word: &str,
    context: &'static str,
    args_text: &str,
    line: usize,
) -> ParseResult<ArgumentGateResult> {
    let rows: Vec<&ArgumentRow> =
        keywords::ARGUMENTS.iter().filter(|r| r.live() && r.keyword == word && r.context == context).collect();

    let segments = if args_text.trim().is_empty() { Vec::new() } else { ruby_value::split_items(args_text) };

    if rows.is_empty() {
        if segments.is_empty() {
            return Ok(ArgumentGateResult::default());
        }
        return Err(Diagnostic::new(file, line, format!("'{word}' takes no arguments, but got '{args_text}'")));
    }

    // A POSITIONAL `pairs` ROW (`at: "1", kind: "pairs"`) — two genuinely
    // different surface shapes share this one `kind`, split by
    // `pairs_shape` (see syntax.bluebook's own `PairsShape` comment):
    //
    //   "fields"              ONE hash-rocket pair — `transition "Purchase"
    //                         => "sold", from: "available"` — real corpus
    //                         syntax (examples/*/bluebook/*.bluebook), not
    //                         Ruby's `key: value` shorthand at all.
    //   "verbatim"/"elements" MANY `identifier: value` segments merged
    //                         into one open map — `member code: "JPY",
    //                         minor_units: 0`.
    if let Some(pairs_row) = rows.iter().find(|r| r.kind == "pairs" && r.at == "1") {
        if pairs_row.pairs_shape == "fields" {
            return argument_gate_fields_pairs(file, word, &rows, pairs_row, &segments, line);
        }
        return argument_gate_named_pairs(file, word, &rows, pairs_row, &segments, line);
    }

    let mut positionals: Vec<String> = Vec::new();
    let mut nameds: Vec<(String, String)> = Vec::new();
    for segment in &segments {
        match as_named(segment) {
            Some((name, value)) => nameds.push((name.to_string(), value.to_string())),
            None => positionals.push(segment.clone()),
        }
    }

    for (idx, text) in positionals.iter().enumerate() {
        let at = (idx + 1).to_string();
        let candidates: Vec<&&ArgumentRow> = rows.iter().filter(|r| r.at == at).collect();
        if candidates.is_empty() {
            return Err(Diagnostic::new(
                file,
                line,
                format!("'{word}' takes at most {idx} positional argument(s), but got another: '{text}'"),
            ));
        }
        let kind = classify_lexical_kind(text);
        if !candidates.iter().any(|r| kind_matches(r.kind, kind)) {
            let expected: Vec<String> = candidates.iter().map(|r| r.kind.to_string()).collect();
            return Err(Diagnostic::new(
                file,
                line,
                format!("'{word}'s positional argument {at} ('{text}') reads as {kind}"),
            )
            .with_expected(expected));
        }
    }

    for (name, value) in &nameds {
        validate_named(file, word, &rows, name, value, line)?;
    }

    for row in &rows {
        if row.required != "true" {
            continue;
        }
        if !row.at.is_empty() {
            let idx: usize = row.at.parse().unwrap_or(0);
            if idx == 0 || idx > positionals.len() {
                return Err(Diagnostic::new(file, line, format!("'{word}' requires a positional argument at {}", row.at)));
            }
        } else if !row.named.is_empty() && !nameds.iter().any(|(n, _)| n == row.named) {
            return Err(Diagnostic::new(file, line, format!("'{word}' requires '{}:'", row.named)));
        }
    }

    Ok(ArgumentGateResult {
        positional: positionals.into_iter().enumerate().map(|(i, t)| (i + 1, t)).collect(),
        named: nameds,
    })
}

/// `pairs_shape: "fields"` — exactly ONE hash-rocket pair
/// (`"Purchase" => "sold"`), contributing two named sub-fields
/// (`pair_key_fills`/`pair_value_fields`) to the record this keyword is
/// already building. Every other top-level segment must be a plain named
/// argument this word separately declares (`from:`, in `transition`'s own
/// case).
fn argument_gate_fields_pairs(
    file: &str,
    word: &str,
    rows: &[&ArgumentRow],
    pairs_row: &ArgumentRow,
    segments: &[String],
    line: usize,
) -> ParseResult<ArgumentGateResult> {
    let mut rocket_pairs: Vec<String> = Vec::new();
    let mut nameds: Vec<(String, String)> = Vec::new();

    for segment in segments {
        if has_top_level_rocket(segment) {
            rocket_pairs.push(segment.clone());
        } else if let Some((name, value)) = as_named(segment) {
            validate_named(file, word, rows, name, value, line)?;
            nameds.push((name.to_string(), value.to_string()));
        } else {
            return Err(Diagnostic::new(
                file,
                line,
                format!("'{word}'s argument '{segment}' is neither a 'key => value' pair nor a named argument"),
            ));
        }
    }

    if rocket_pairs.len() > 1 {
        return Err(Diagnostic::new(file, line, format!("'{word}' takes exactly one 'key => value' pair, got {}", rocket_pairs.len())));
    }
    if pairs_row.required == "true" && rocket_pairs.is_empty() {
        return Err(Diagnostic::new(file, line, format!("'{word}' requires a 'key => value' pair")));
    }

    let named = rocket_pairs.into_iter().map(|pair| ("=>".to_string(), pair)).chain(nameds).collect();
    Ok(ArgumentGateResult { positional: Vec::new(), named })
}

/// `pairs_shape: "verbatim"`/`"elements"` — MANY `identifier: value`
/// segments merged into one open map (`member code: "JPY", minor_units:
/// 0`), distinguished from a more specific `named:` row (claimed
/// individually) by not matching any such row's own name.
fn argument_gate_named_pairs(
    file: &str,
    word: &str,
    rows: &[&ArgumentRow],
    pairs_row: &ArgumentRow,
    segments: &[String],
    line: usize,
) -> ParseResult<ArgumentGateResult> {
    let mut positionals: Vec<String> = Vec::new();
    let mut nameds: Vec<(String, String)> = Vec::new();
    for segment in segments {
        match as_named(segment) {
            Some((name, value)) => nameds.push((name.to_string(), value.to_string())),
            None => positionals.push(segment.clone()),
        }
    }

    if !positionals.is_empty() {
        return Err(Diagnostic::new(file, line, format!("'{word}' takes an open map of pairs, not a bare positional argument")));
    }

    let specific_named: std::collections::BTreeSet<&str> = rows.iter().filter(|r| !r.named.is_empty()).map(|r| r.named).collect();
    let mut claimed = Vec::new();
    let mut leftover = Vec::new();
    for (name, value) in nameds {
        if specific_named.contains(name.as_str()) {
            claimed.push((name, value));
        } else {
            leftover.push((name, value));
        }
    }

    if pairs_row.required == "true" && leftover.is_empty() {
        return Err(Diagnostic::new(file, line, format!("'{word}' requires at least one pair")));
    }

    for (name, value) in &claimed {
        validate_named(file, word, rows, name, value, line)?;
    }

    let mut named = claimed;
    named.extend(leftover);
    Ok(ArgumentGateResult { positional: Vec::new(), named })
}

/// A top-level (not inside quotes/braces/brackets) Ruby hash-rocket
/// `=>` — `"Purchase" => "sold"`, real corpus syntax for a `pairs_shape:
/// "fields"` argument (transition's own row). Deliberately distinct from
/// `as_named`'s `identifier:` detection: the two spellings never overlap
/// in this language, so no segment is ever ambiguous between them.
fn has_top_level_rocket(text: &str) -> bool {
    let mut quoting = false;
    let mut escaping = false;
    let mut depth: i32 = 0;
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let ch = chars[i];
        if escaping {
            escaping = false;
            i += 1;
            continue;
        }
        if quoting && ch == '\\' {
            escaping = true;
            i += 1;
            continue;
        }
        if ch == '"' {
            quoting = !quoting;
            i += 1;
            continue;
        }
        if quoting {
            i += 1;
            continue;
        }
        match ch {
            '{' | '[' => depth += 1,
            '}' | ']' => depth -= 1,
            '=' if depth == 0 && chars.get(i + 1) == Some(&'>') => return true,
            _ => {}
        }
        i += 1;
    }
    false
}

fn validate_named(
    file: &str,
    word: &str,
    rows: &[&ArgumentRow],
    name: &str,
    value: &str,
    line: usize,
) -> ParseResult<()> {
    let candidates: Vec<&&ArgumentRow> = rows.iter().filter(|r| r.named == name).collect();
    if candidates.is_empty() {
        let expected: Vec<String> = rows.iter().filter(|r| !r.named.is_empty()).map(|r| r.named.to_string()).collect();
        return Err(Diagnostic::new(file, line, format!("'{word}' takes no '{name}:' argument")).with_expected(expected));
    }
    let kind = classify_lexical_kind(value);
    if !candidates.iter().any(|r| kind_matches(r.kind, kind)) {
        let expected: Vec<String> = candidates.iter().map(|r| r.kind.to_string()).collect();
        return Err(Diagnostic::new(file, line, format!("'{word}'s '{name}:' ('{value}') reads as {kind}")).with_expected(expected));
    }
    Ok(())
}

/// Maps a `KeywordRow.inner` context name (the body the word opens) to the
/// per-construct module responsible for it, per the same BUILDER grouping
/// `spec/syntax_conformance_spec.rb` already uses (`OneOf` shares
/// `ValueObjectBuilder`, `Handler` shares `ProcessManagerBuilder`,
/// `PortOperation` shares `DomainPortBuilder`).
fn dispatch_stub(inner_context: &str, file: &str, line: usize, word: &str) -> Diagnostic {
    match inner_context {
        "Bluebook" => chapter::not_implemented(file, line, word),
        "Hecksagon" => hecksagon::not_implemented(file, line, word),
        "Aggregate" => aggregate::not_implemented(file, line, word),
        "Entity" => entity::not_implemented(file, line, word),
        "Command" => command::not_implemented(file, line, word),
        "Query" => query::not_implemented(file, line, word),
        "ValueObject" | "OneOf" => value_object::not_implemented(file, line, word),
        "Lifecycle" => lifecycle::not_implemented(file, line, word),
        "Policy" => policy::not_implemented(file, line, word),
        "ProcessManager" | "Handler" => process_manager::not_implemented(file, line, word),
        "ReadModel" => read_model::not_implemented(file, line, word),
        "DomainPort" | "PortOperation" => domain_port::not_implemented(file, line, word),
        // WORLD IS DELIBERATELY UNMAPPED — its body is the open
        // verb-setting catch-all (syntax.bluebook's own NOT_A_WORD note
        // on WorldBuilder#method_missing). The two narrow open-vocabulary
        // escapes the plan names (`.hecksagon` adapter-bind,
        // `.world` verb-setting — shape-matched and dropped, never
        // interpreted) are real Stage 2+ work; today a `world do ... end`
        // body's own content still goes through the closed word gate like
        // everything else and refuses there, which is the honest
        // (if not yet final) Stage 1 behavior — named here rather than
        // silently guessed at.
        other => Diagnostic::not_yet_implemented(file, line, format!("{other}.{word} (unmapped inner context)")),
    }
}

/// The recursive body-walker. Walks lines inside an already-open
/// `context`, from `*pos` up to (and consuming) the matching `end`. Every
/// line is gated for real regardless of depth; a `do`-opening line
/// recurses into its own `inner` context before this function decides
/// whether to report it as not-yet-implemented. Reaching a line that
/// fully gates but doesn't (yet) build anything — or successfully
/// recursing through an entire nested body with nothing left to build —
/// is where Stage 1 honestly stops: `Diagnostic::not_yet_implemented`.
///
/// FIRST ERROR ABORTS, deliberately (see the plan's own non-goals on
/// parser error recovery) — this returns on the FIRST gate failure or
/// first not-yet-implemented construct, at any depth.
pub fn walk_body(file: &str, lines: &[SourceLine], pos: &mut usize, context: &'static str) -> ParseResult<()> {
    loop {
        let line = *lines.get(*pos).ok_or_else(|| {
            let last = lines.last().map(|l| l.number).unwrap_or(0);
            Diagnostic::new(file, last, format!("unexpected end of file — still inside {context}"))
        })?;

        let shape = lex::classify(file, &line)?;
        *pos += 1;

        match shape {
            LineShape::End => return Ok(()),
            LineShape::Call(call) => handle_call(file, lines, pos, context, &line, call)?,
        }
    }
}

fn handle_call(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    context: &'static str,
    line: &SourceLine,
    call: Call,
) -> ParseResult<()> {
    let candidates = word_gate(file, &call.word, context, line.number)?;
    let row = body_gate(file, &candidates, &call.opener, line.number, &call.word)?;
    argument_gate(file, &call.word, context, &call.args, line.number)?;

    match &call.opener {
        Opener::DoBlock { .. } => {
            if row.inner.is_empty() {
                return Err(dispatch_stub(context, file, line.number, &call.word));
            }
            let inner_context = keywords::CONTEXTS
                .iter()
                .find(|c| **c == row.inner)
                .copied()
                .ok_or_else(|| Diagnostic::new(file, line.number, format!("'{}' opens an undeclared context '{}'", call.word, row.inner)))?;
            walk_body(file, lines, pos, inner_context)?;
            // The ENTIRE nested body (`inner_context`) gated successfully
            // with no leaf construct left unimplemented inside it — still
            // not implemented at Stage 1 (build/*.rs and ir.rs are stubs,
            // see their own headers), so the construct JUST RECURSED INTO
            // is the honest failure point, not the outer `context` that
            // merely opened it.
            Err(dispatch_stub(inner_context, file, line.number, &call.word))
        }
        Opener::BraceBlock { .. } | Opener::None => Err(dispatch_stub(context, file, line.number, &call.word)),
    }
}
