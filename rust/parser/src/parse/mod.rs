//! Word, body, and argument gates, plus the recursive body walker.
//! Per-construct modules build IR; a word they do not build fails with `not_yet_implemented`.

pub mod aggregate;
pub mod chapter;
pub mod command;
pub mod domain_port;
pub mod entity;
pub mod file;
pub mod hecksagon;
pub mod lifecycle;
pub mod needs;
pub mod policy;
pub mod process_manager;
pub mod query;
pub mod read_model;
pub mod value_object;

use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::keywords::{self, ArgumentRow, KeywordRow};
use crate::lex::{self, Call, LineShape, Opener, SourceLine};
use crate::ruby_value;

/// Live `KeywordRow`s for `(word, context)`; zero rows is an error listing the legal words.
pub fn word_gate<'a>(
    file: &str,
    word: &str,
    context: &'static str,
    line: usize,
) -> ParseResult<Vec<&'a KeywordRow>> {
    // A renamed word matches under either spelling (`sets` / `then_set`); `was` is never a row.
    let candidates: Vec<&KeywordRow> = keywords::KEYWORDS
        .iter()
        .filter(|k| {
            k.live()
                && k.context == context
                && (k.word == word || (!k.was.is_empty() && k.was == word))
        })
        .collect();

    if candidates.is_empty() {
        let mut legal: Vec<String> = keywords::KEYWORDS
            .iter()
            .filter(|k| k.live() && k.context == context)
            .map(|k| k.word.to_string())
            .collect();
        legal.sort();
        legal.dedup();
        return Err(Diagnostic::new(
            file,
            line,
            format!("'{word}' is not a word {context} admits"),
        )
        .with_expected(legal));
    }

    Ok(candidates)
}

/// Picks the word-gated row whose declared `body` fits the opener the lexer found.
///
/// `do ... end` and `{ ... }` are interchangeable for `source`/`keywords`/`rows` bodies, so the
/// delimiter never decides the row. No `(word, context)` declares both a `source` row and a
/// `keywords`/`rows` row; if one ever does, this widening becomes the tie-break.
pub fn body_gate<'a>(
    file: &str,
    candidates: &[&'a KeywordRow],
    opener: &Opener,
    line: usize,
    word: &str,
) -> ParseResult<&'a KeywordRow> {
    let compatible: fn(&str) -> bool = match opener {
        Opener::None => |body| body == "none",
        Opener::DoBlock { .. } => |body| body == "keywords" || body == "rows" || body == "source",
        Opener::BraceBlock { .. } => {
            |body| body == "keywords" || body == "rows" || body == "source"
        }
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
    Err(
        Diagnostic::new(file, line, format!("'{word}' was written with {found}"))
            .with_expected(legal),
    )
}

/// Checks that `syntax.bluebook`'s `resolves_via` for `(word, context)` matches the caller's use.
/// Mirrors Ruby's `RuleReference#verify_resolves_via!`; a mismatch means the two have drifted.
pub fn verify_resolves_via(
    file: &str,
    line: usize,
    word: &str,
    context: &'static str,
    expected: &str,
) -> ParseResult<()> {
    let actual = keywords::KEYWORDS
        .iter()
        .find(|k| k.word == word && k.context == context)
        .map_or("", |k| k.resolves_via);

    if actual == expected {
        return Ok(());
    }

    Err(Diagnostic::new(
        file,
        line,
        format!(
            "internal: syntax.bluebook says {word}/{context} resolves via '{actual}', but \
             {word}'s own Rust parser is about to use '{expected}' — the grammar table and \
             the implementation have drifted"
        ),
    ))
}

pub(crate) fn kind_matches(declared: &str, actual: &str) -> bool {
    if declared == actual {
        return true;
    }
    // `literal` is the widest kind: a Hash or Array survives its type like a number or symbol does
    // (`sets :toppings, append: { ... }`). Only a `constant` type name is excluded.
    declared == "literal" && actual != "constant"
}

/// A `word(...)` call whose word is a live `Type`-context word (`list_of`, `one_of`).
/// It fills a `constant` slot although it does not start with an uppercase letter.
pub(crate) fn type_context_call_word(token: &str) -> Option<&str> {
    let open = token.find('(')?;
    if !token.ends_with(')') {
        return None;
    }
    let word = &token[..open];
    if word.is_empty() || !word.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return None;
    }
    if keywords::KEYWORDS
        .iter()
        .any(|k| k.live() && k.context == "Type" && k.word == word)
    {
        Some(word)
    } else {
        None
    }
}

pub(crate) fn classify_lexical_kind(token: &str) -> &'static str {
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
    if t.chars()
        .next()
        .map(|c| c.is_ascii_uppercase())
        .unwrap_or(false)
    {
        return "constant";
    }
    if type_context_call_word(t).is_some() {
        return "constant";
    }
    // Fallback for an unquoted bare word with no sharper classification.
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

/// Splits a named `identifier: value` segment; a leading colon (`:eq`) or `::` is not named.
pub(crate) fn as_named(segment: &str) -> Option<(&str, &str)> {
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

/// Checks positional/named count and lexical kind against the `ArgumentRow`s of `(word, context)`.
/// Rows join on `(word, context)` alone, not on the chosen body row (`identified_by` shares them).
pub fn argument_gate(
    file: &str,
    word: &str,
    context: &'static str,
    args_text: &str,
    line: usize,
) -> ParseResult<ArgumentGateResult> {
    let rows: Vec<&ArgumentRow> = keywords::ARGUMENTS
        .iter()
        .filter(|r| r.live() && r.keyword == word && r.context == context)
        .collect();

    let segments = if args_text.trim().is_empty() {
        Vec::new()
    } else {
        ruby_value::split_items(args_text)
    };

    if rows.is_empty() {
        if segments.is_empty() {
            return Ok(ArgumentGateResult::default());
        }
        return Err(Diagnostic::new(
            file,
            line,
            format!("'{word}' takes no arguments, but got '{args_text}'"),
        ));
    }

    // A positional `pairs` row covers two shapes, split by `pairs_shape`: "fields" is one
    // hash-rocket pair (`transition "Purchase" => "sold"`); "verbatim"/"elements" is many
    // `key: value` segments merged into one open map (`member code: "JPY"`).
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
        let mut candidates: Vec<&&ArgumentRow> = rows.iter().filter(|r| r.at == at).collect();
        if candidates.is_empty() {
            // A variadic row (`group_by`'s `*fields`) repeats for every position past its `at`;
            // `one_of`'s repetition is hand-parsed in `resolve_type_expression`, not here.
            if let Some(row) = rows.iter().find(|r| r.variadic == "true") {
                candidates.push(row);
            }
        }
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
                return Err(Diagnostic::new(
                    file,
                    line,
                    format!("'{word}' requires a positional argument at {}", row.at),
                ));
            }
        } else if !row.named.is_empty() && !nameds.iter().any(|(n, _)| n == row.named) {
            return Err(Diagnostic::new(
                file,
                line,
                format!("'{word}' requires '{}:'", row.named),
            ));
        }
    }

    Ok(ArgumentGateResult {
        positional: positionals
            .into_iter()
            .enumerate()
            .map(|(i, t)| (i + 1, t))
            .collect(),
        named: nameds,
    })
}

/// `pairs_shape: "fields"`: exactly one hash-rocket pair (`"Purchase" => "sold"`).
///
/// An unclaimed `key: value` segment (`transition from: "pending", to: "received"`) is Ruby's hash
/// shorthand for the same pair, so it is rewritten to `"key" => value` and the transition is named
/// after the key (`"to"`). Segments a row declares by name (`from:`) are validated as named args.
fn argument_gate_fields_pairs(
    file: &str,
    word: &str,
    rows: &[&ArgumentRow],
    pairs_row: &ArgumentRow,
    segments: &[String],
    line: usize,
) -> ParseResult<ArgumentGateResult> {
    let mut field_pairs: Vec<String> = Vec::new();
    let mut nameds: Vec<(String, String)> = Vec::new();

    for segment in segments {
        if has_top_level_rocket(segment) {
            field_pairs.push(segment.clone());
        } else if let Some((name, value)) = as_named(segment) {
            let specifically_declared = rows.iter().any(|r| r.kind != "pairs" && r.named == name);
            if specifically_declared {
                validate_named(file, word, rows, name, value, line)?;
                nameds.push((name.to_string(), value.to_string()));
            } else {
                field_pairs.push(format!("\"{name}\" => {value}"));
            }
        } else {
            return Err(Diagnostic::new(
                file,
                line,
                format!("'{word}'s argument '{segment}' is neither a 'key => value' pair nor a named argument"),
            ));
        }
    }

    if field_pairs.len() > 1 {
        return Err(Diagnostic::new(
            file,
            line,
            format!(
                "'{word}' takes exactly one 'key => value' pair, got {}",
                field_pairs.len()
            ),
        ));
    }
    if pairs_row.required == "true" && field_pairs.is_empty() {
        return Err(Diagnostic::new(
            file,
            line,
            format!("'{word}' requires a 'key => value' pair"),
        ));
    }

    let named = field_pairs
        .into_iter()
        .map(|pair| ("=>".to_string(), pair))
        .chain(nameds)
        .collect();
    Ok(ArgumentGateResult {
        positional: Vec::new(),
        named,
    })
}

/// `pairs_shape: "verbatim"`/`"elements"`: many segments merged into one open map.
///
/// A key that is not a bare identifier (a dotted query path) needs Ruby's `:"a.b" => v` spelling,
/// so a top-level rocket segment is accepted beside `key: value`; the two never overlap.
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
        if let Some((name, value)) = as_named(segment) {
            nameds.push((name.to_string(), value.to_string()));
            continue;
        }
        if has_top_level_rocket(segment) {
            let (key_text, value_text) = split_top_level_rocket(segment);
            let name = rocket_key_name(file, word, key_text, line)?;
            nameds.push((name, value_text.to_string()));
            continue;
        }
        positionals.push(segment.clone());
    }

    if !positionals.is_empty() {
        return Err(Diagnostic::new(
            file,
            line,
            format!("'{word}' takes an open map of pairs, not a bare positional argument"),
        ));
    }

    let specific_named: std::collections::BTreeSet<&str> = rows
        .iter()
        .filter(|r| !r.named.is_empty())
        .map(|r| r.named)
        .collect();
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
        return Err(Diagnostic::new(
            file,
            line,
            format!("'{word}' requires at least one pair"),
        ));
    }

    for (name, value) in &claimed {
        validate_named(file, word, rows, name, value, line)?;
    }

    let mut named = claimed;
    named.extend(leftover);
    Ok(ArgumentGateResult {
        positional: Vec::new(),
        named,
    })
}

/// True when `text` holds a `=>` outside quotes, braces and brackets.
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

/// Splits a segment already known (`has_top_level_rocket`) to contain a
/// top-level `=>` into `(key_text, value_text)`, both trimmed.
pub(crate) fn split_top_level_rocket(segment: &str) -> (&str, &str) {
    let mut quoting = false;
    let mut escaping = false;
    let mut depth: i32 = 0;
    let bytes = segment.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let ch = bytes[i] as char;
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
        if !quoting {
            match ch {
                '{' | '[' => depth += 1,
                '}' | ']' => depth -= 1,
                '=' if depth == 0 && bytes.get(i + 1) == Some(&b'>') => {
                    return (segment[..i].trim(), segment[i + 2..].trim());
                }
                _ => {}
            }
        }
        i += 1;
    }
    (segment.trim(), "")
}

/// The field name of a pair key, a bare or quoted Symbol literal (`:status`, `:"a.b"`).
/// Any other key is refused; pair keys are always symbols.
fn rocket_key_name<'a>(
    file: &str,
    word: &str,
    key_text: &'a str,
    line: usize,
) -> ParseResult<String> {
    let Some(rest) = key_text.strip_prefix(':') else {
        return Err(Diagnostic::new(file, line, format!("'{word}'s key '{key_text}' is not a symbol — a pair's key is always :name or :\"a.dotted.path\"")));
    };
    if rest.len() >= 2 && rest.starts_with('"') && rest.ends_with('"') {
        return Ok(ruby_value::unquote_for_symbol(rest));
    }
    Ok(rest.to_string())
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
        let expected: Vec<String> = rows
            .iter()
            .filter(|r| !r.named.is_empty())
            .map(|r| r.named.to_string())
            .collect();
        return Err(
            Diagnostic::new(file, line, format!("'{word}' takes no '{name}:' argument"))
                .with_expected(expected),
        );
    }
    let kind = classify_lexical_kind(value);
    if !candidates.iter().any(|r| kind_matches(r.kind, kind)) {
        let expected: Vec<String> = candidates.iter().map(|r| r.kind.to_string()).collect();
        return Err(Diagnostic::new(
            file,
            line,
            format!("'{word}'s '{name}:' ('{value}') reads as {kind}"),
        )
        .with_expected(expected));
    }
    Ok(())
}

/// Maps a `KeywordRow.inner` context to its per-construct module's `not_implemented` diagnostic.
pub(crate) fn dispatch_stub(
    inner_context: &str,
    file: &str,
    line: usize,
    word: &str,
) -> Diagnostic {
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
        // `World` is deliberately unmapped: its body is the open verb-setting catch-all, so it
        // falls through to the closed word gate and refuses there.
        other => Diagnostic::not_yet_implemented(
            file,
            line,
            format!("{other}.{word} (unmapped inner context)"),
        ),
    }
}

/// Fallback diagnostic for a word this parser does not build IR for.
/// `tests/gates.rs` depends on its wording staying stable.
pub(crate) fn not_built_yet(
    context: &str,
    row: &KeywordRow,
    file: &str,
    line: usize,
    word: &str,
) -> Diagnostic {
    if row.inner.is_empty() {
        dispatch_stub(context, file, line, word)
    } else {
        dispatch_stub(row.inner, file, line, word)
    }
}

/// One gated line: all four gates have run, and any nested body is left unconsumed.
/// The caller decides whether to recurse into it.
pub(crate) struct GatedLine<'src> {
    pub line: SourceLine<'src>,
    pub call: Call,
    // Always `'static`: every `KeywordRow` lives in the generated `KEYWORDS` slice.
    pub row: &'static KeywordRow,
    pub args: ArgumentGateResult,
}

/// Gates the next line in `context`; `None` means `end` was consumed, `Some` a legal call.
/// `*pos` advances past the line, never past a nested body.
pub(crate) fn next_line<'src>(
    file: &str,
    lines: &[SourceLine<'src>],
    pos: &mut usize,
    context: &'static str,
) -> ParseResult<Option<GatedLine<'src>>> {
    let line = *lines.get(*pos).ok_or_else(|| {
        let last = lines.last().map(|l| l.number).unwrap_or(0);
        Diagnostic::new(
            file,
            last,
            format!("unexpected end of file — still inside {context}"),
        )
    })?;

    let shape = lex::classify(file, &line)?;
    *pos += 1;

    match shape {
        LineShape::End => Ok(None),
        LineShape::Call(call) => {
            let candidates: Vec<&'static KeywordRow> =
                word_gate(file, &call.word, context, line.number)?;
            let row: &'static KeywordRow =
                body_gate(file, &candidates, &call.opener, line.number, &call.word)?;
            let args = argument_gate(file, row.word, context, &call.args, line.number)?;
            Ok(Some(GatedLine {
                line,
                call,
                row,
                args,
            }))
        }
    }
}

/// The N'th (1-based) positional's raw text; missing is a defensive error after `argument_gate`.
fn positional_raw<'a>(
    file: &str,
    line: usize,
    word: &str,
    args: &'a ArgumentGateResult,
    at: usize,
) -> ParseResult<&'a str> {
    args.positional
        .iter()
        .find(|(idx, _)| *idx == at)
        .map(|(_, text)| text.as_str())
        .ok_or_else(|| {
            Diagnostic::new(
                file,
                line,
                format!("'{word}' has no positional argument {at}"),
            )
        })
}

/// A required text (quoted-string) positional argument, unquoted —
/// `aggregate "Widget"`, `given("description")`, `role "Chef"`.
pub(crate) fn positional_text(
    file: &str,
    line: usize,
    word: &str,
    args: &ArgumentGateResult,
    at: usize,
) -> ParseResult<String> {
    let raw = positional_raw(file, line, word, args, at)?;
    Ok(match ruby_value::read(raw) {
        ruby_value::Value::Str(s) => s,
        other => ruby_value::to_s(&other),
    })
}

/// Like `positional_text`, but the argument must be a literal. Ruby evaluates what follows
/// `role` or `goal`, so a bare word or a call there (`role sets :name`) is an expression this
/// parser cannot evaluate, and reading its source text as the value would invent one.
pub(crate) fn positional_literal_text(
    file: &str,
    line: usize,
    word: &str,
    args: &ArgumentGateResult,
    at: usize,
) -> ParseResult<String> {
    let raw = positional_raw(file, line, word, args, at)?;
    match ruby_value::read(raw) {
        ruby_value::Value::Bare(_) => Err(Diagnostic::new(
            file,
            line,
            format!(
                "'{word}'s positional argument {at} ('{}') is not a literal",
                raw.trim()
            ),
        )),
        ruby_value::Value::Str(s) => Ok(s),
        literal => Ok(ruby_value::to_s(&literal)),
    }
}

/// A required symbol positional without its colon (`attribute :name`), bare or quoted (`:"a.b"`).
/// The quoted form spells dotted paths, e.g. `correlates_by :"reference.value"`.
pub(crate) fn positional_symbol(
    file: &str,
    line: usize,
    word: &str,
    args: &ArgumentGateResult,
    at: usize,
) -> ParseResult<String> {
    let raw = positional_raw(file, line, word, args, at)?.trim();
    symbol_text(raw).ok_or_else(|| {
        Diagnostic::new(
            file,
            line,
            format!("'{word}'s positional argument {at} ('{raw}') is not a symbol"),
        )
    })
}

/// The name in a source symbol token: `:name` -> `name`, `:"a.b"` -> `a.b`.
/// Not `ruby_value::read`, which reads rendered wire values rather than source syntax.
fn symbol_text(raw: &str) -> Option<String> {
    let rest = raw.strip_prefix(':')?;
    if rest.len() >= 2 && rest.starts_with('"') && rest.ends_with('"') {
        Some(ruby_value::unquote_for_symbol(rest))
    } else {
        Some(rest.to_string())
    }
}

/// A constant (bareword type name) positional argument, raw — `attribute
/// :pizza, Pizza`. Never quoted, never colon-prefixed; taken verbatim.
pub(crate) fn positional_constant<'a>(
    file: &str,
    line: usize,
    word: &str,
    args: &'a ArgumentGateResult,
    at: usize,
) -> ParseResult<&'a str> {
    positional_raw(file, line, word, args, at).map(|s| s.trim())
}

/// A command reference: bare constant (`trigger Account::Debit`) or quoted (`"Account.Debit"`).
/// Derives the same text as `Hecks::Naming.command_ref`.
pub(crate) fn positional_command_ref(
    file: &str,
    line: usize,
    word: &str,
    args: &ArgumentGateResult,
    at: usize,
) -> ParseResult<String> {
    let raw = positional_raw(file, line, word, args, at)?;
    Ok(crate::build::naming::command_ref(raw))
}

/// A process manager's event reference (`starts_on Transfer::TransferRequested`), bare or quoted.
/// Derives `Hecks::Naming.event_name_ref`, which keeps only the bare final segment.
pub(crate) fn positional_event_name_ref(
    file: &str,
    line: usize,
    word: &str,
    args: &ArgumentGateResult,
    at: usize,
) -> ParseResult<String> {
    let raw = positional_raw(file, line, word, args, at)?;
    Ok(crate::build::naming::event_name_ref(raw))
}

/// A named argument's raw captured text, if the call gave one —
/// `as: :name`, `optional: true`, `to: "sold"`.
pub(crate) fn named_raw<'a>(args: &'a ArgumentGateResult, name: &str) -> Option<&'a str> {
    args.named
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, v)| v.as_str())
}

/// A named constant argument (`to: Payment`): raw text, trimmed; resolved downstream.
pub(crate) fn named_constant<'a>(args: &'a ArgumentGateResult, name: &str) -> Option<&'a str> {
    named_raw(args, name).map(|s| s.trim())
}

/// A named symbol argument without its colon (`as: :name`); bare or quoted.
pub(crate) fn named_symbol(args: &ArgumentGateResult, name: &str) -> Option<String> {
    named_raw(args, name).and_then(|raw| symbol_text(raw.trim()))
}

/// A named text argument, unquoted.
pub(crate) fn named_text(args: &ArgumentGateResult, name: &str) -> Option<String> {
    named_raw(args, name).map(|raw| match ruby_value::read(raw) {
        ruby_value::Value::Str(s) => s,
        other => ruby_value::to_s(&other),
    })
}

/// A named flag (`true`/`false`) argument — `optional: true`.
pub(crate) fn named_flag(args: &ArgumentGateResult, name: &str) -> bool {
    named_raw(args, name)
        .map(|raw| raw.trim() == "true")
        .unwrap_or(false)
}

/// Raw text of a `source`-shaped body written as `{ ... }` or `do ... end`.
/// Shared by `identified_by`, `given` and `invariant`.
pub(crate) fn source_body_text(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    opener: &Opener,
) -> ParseResult<String> {
    match opener {
        Opener::BraceBlock { body } => Ok(body.clone()),
        Opener::DoBlock { .. } => lex::capture_do_block_body(file, lines, pos),
        Opener::None => {
            unreachable!("body_gate only ever admits BraceBlock/DoBlock for a `source`-bodied row")
        }
    }
}

/// Runs `parse` over a nested `keywords`/`rows` body written with `do ... end` or `{ ... }`.
///
/// A brace body is split into synthetic one-statement lines ending in `end`, so the per-construct
/// `parse_body` functions, which walk `(lines, pos)`, need no second code path.
pub(crate) fn parse_nested_body<T>(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    opener: &Opener,
    line_number: usize,
    parse: impl FnOnce(&str, &[SourceLine], &mut usize) -> ParseResult<T>,
) -> ParseResult<T> {
    match opener {
        Opener::BraceBlock { body } => {
            let owned = brace_body_statements(body);
            let synthetic: Vec<SourceLine> = owned
                .iter()
                .map(|text| SourceLine {
                    number: line_number,
                    text: text.as_str(),
                })
                .collect();
            let mut synthetic_pos = 0;
            parse(file, &synthetic, &mut synthetic_pos)
        }
        _ => parse(file, lines, pos),
    }
}

/// Splits a captured `{ ... }` body on top-level `;` (outside quotes, braces, brackets, parens).
/// Ends with a synthetic `"end"` so callers can treat it as an ordinary body.
fn brace_body_statements(body: &str) -> Vec<String> {
    let mut statements: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut depth: i32 = 0;
    let mut quoting = false;
    let mut escaping = false;

    for ch in body.chars() {
        if escaping {
            current.push(ch);
            escaping = false;
            continue;
        }
        if quoting && ch == '\\' {
            current.push(ch);
            escaping = true;
            continue;
        }
        if ch == '"' {
            quoting = !quoting;
            current.push(ch);
            continue;
        }
        if quoting {
            current.push(ch);
            continue;
        }
        match ch {
            '{' | '[' | '(' => depth += 1,
            '}' | ']' | ')' => depth -= 1,
            ';' if depth == 0 => {
                statements.push(current.trim().to_string());
                current.clear();
                continue;
            }
            _ => {}
        }
        current.push(ch);
    }
    statements.push(current.trim().to_string());

    let mut statements: Vec<String> = statements.into_iter().filter(|s| !s.is_empty()).collect();
    statements.push("end".to_string());
    statements
}

/// An `entity`/`command`/`query` body recorded for later parsing, like Ruby's `#drain_pending!`.
///
/// Nested constructs resolve against the owner's complete `value_objects`/`entities`/
/// `preconditions`, so the body is located here (skipping a `do ... end` block) and parsed by
/// `build_deferred` once the owner has been fully walked.
pub(crate) struct PendingBody {
    opener: Opener,
    line_number: usize,
    body_start: usize,
}

/// Records the body starting at `*pos` once its opening line is gated; see `PendingBody`.
pub(crate) fn defer_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    opener: &Opener,
    line_number: usize,
) -> ParseResult<PendingBody> {
    let body_start = *pos;
    if matches!(opener, Opener::DoBlock { .. }) {
        lex::capture_do_block_body(file, lines, pos)?;
    }
    Ok(PendingBody {
        opener: opener.clone(),
        line_number,
        body_start,
    })
}

/// Parses a deferred body via `parse_nested_body`; `lines` must be the slice `defer_body` saw.
pub(crate) fn build_deferred<T>(
    file: &str,
    lines: &[SourceLine],
    pending: &PendingBody,
    parse: impl FnOnce(&str, &[SourceLine], &mut usize) -> ParseResult<T>,
) -> ParseResult<T> {
    let mut pos = pending.body_start;
    parse_nested_body(
        file,
        lines,
        &mut pos,
        &pending.opener,
        pending.line_number,
        parse,
    )
}

/// The `identified_by` forms resolved for both `parse::aggregate` and `parse::entity`.
/// `Fields` (ADR 0025) resolves each symbol against an already-declared attribute.
pub(crate) enum PendingIdentity {
    Type {
        line: usize,
        target: String,
        as_field: Option<String>,
        insert_at: usize,
    },
    Fields {
        line: usize,
        names: Vec<String>,
    },
    Inline {
        line: usize,
        value_object: ir::ValueObject,
        as_field: Option<String>,
        insert_at: usize,
    },
}

/// Parses `identified_by` in its three forms: a value object type (`PizzaName, as: :name`), one or
/// more field symbols (`:a, :b`), or a `{ ... }`/`do ... end` block declaring an inline value
/// object named `inline_type_name`.
pub(crate) fn parse_identified_by(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    line: usize,
    args: &ArgumentGateResult,
    opener: &Opener,
    insert_at: usize,
    inline_type_name: &str,
    owner_value_objects: &[ir::ValueObject],
) -> ParseResult<PendingIdentity> {
    match opener {
        Opener::None => {
            let text = positional_constant(file, line, "identified_by", args, 1)?;
            match classify_lexical_kind(text) {
                "constant" => {
                    let as_field = named_symbol(args, "as");
                    Ok(PendingIdentity::Type { line, target: text.to_string(), as_field, insert_at })
                }
                "symbol" => {
                    let names: Vec<String> = args.positional.iter().map(|(_, raw)| positional_symbol_text(file, line, "identified_by", raw)).collect::<ParseResult<_>>()?;
                    Ok(PendingIdentity::Fields { line, names })
                }
                other => Err(Diagnostic::new(file, line, format!("'identified_by's positional argument reads as {other}, neither a value object nor a field"))),
            }
        }
        Opener::DoBlock { .. } | Opener::BraceBlock { .. } => {
            if !args.positional.is_empty() {
                return Err(Diagnostic::new(
                    file,
                    line,
                    "'identified_by' cannot combine a value-object type with a block",
                ));
            }
            let value_object = parse_nested_body(file, lines, pos, opener, line, |f, l, p| {
                value_object::parse_body(f, l, p, inline_type_name, owner_value_objects)
            })?;
            if value_object.attributes.is_empty() {
                return Err(Diagnostic::new(
                    file,
                    line,
                    "'identified_by do' declares no identity attributes",
                ));
            }
            Ok(PendingIdentity::Inline {
                line,
                value_object,
                as_field: named_symbol(args, "as"),
                insert_at,
            })
        }
    }
}

/// The N'th positional as a symbol name (`:holds_seat` gives `holds_seat`).
pub(crate) fn positional_symbol_raw(
    file: &str,
    line: usize,
    word: &str,
    args: &ArgumentGateResult,
    at: usize,
) -> ParseResult<String> {
    let raw = positional_raw(file, line, word, args, at)?;
    positional_symbol_text(file, line, word, raw)
}

/// Symbol name for one raw positional token, for variadic callers such as `identified_by`.
fn positional_symbol_text(file: &str, line: usize, word: &str, raw: &str) -> ParseResult<String> {
    let trimmed = raw.trim();
    symbol_text(trimmed).ok_or_else(|| {
        Diagnostic::new(
            file,
            line,
            format!("'{word}'s positional argument ('{trimmed}') is not a symbol"),
        )
    })
}

/// Builds an attribute and, for an inline `one_of(...)` type, its synthesized closed set.
/// Only `parse::aggregate` keeps that value object; other callers discard it.
pub(crate) fn build_attribute(
    file: &str,
    line: usize,
    word: &str,
    args: &ArgumentGateResult,
) -> ParseResult<(ir::Attribute, Option<ir::ValueObject>)> {
    let name = positional_symbol(file, line, word, args, 1)?;
    // The type position is a bare constant and always required; there is no default.
    let (_, text) = args
        .positional
        .iter()
        .find(|(idx, _)| *idx == 2)
        .ok_or_else(|| Diagnostic::new(file, line, format!("'{name}' declares no type — attribute :{name}, SomeType is required, there is no default")))?;
    let (type_name, list, closed_set) = resolve_type_expression(file, line, word, &name, text)?;
    let default = named_raw(args, "default").map(ruby_value::read);
    let optional = named_flag(args, "optional");
    let pattern = named_text(args, "pattern");
    let admits = named_text(args, "admits");
    // Fail closed at declaration time on a pattern outside the shared subset, as Ruby does.
    if let Some(pat) = &pattern {
        if let Some(rejection) = crate::build::pattern_subset::validate(pat) {
            return Err(Diagnostic::new(
                file,
                line,
                format!(
                    "'{name}'s pattern {pat:?} uses a {} — {}",
                    rejection.construct, rejection.reason
                ),
            ));
        }
    }
    Ok((
        ir::Attribute {
            name,
            type_name,
            list,
            default,
            optional,
            pattern,
            admits,
            relationship: None,
        },
        closed_set,
    ))
}

/// Resolves an attribute's type: a bare constant, `list_of(T)`, or an inline `one_of(...)`.
///
/// `list_of` unwraps to `(inner, true)`. `one_of` synthesizes a closed-set value object named
/// after the field, as `AttributeCollector#synthesise_closed_set` does, and returns it.
pub(crate) fn resolve_type_expression(
    file: &str,
    line: usize,
    word: &str,
    field_name: &str,
    text: &str,
) -> ParseResult<(String, bool, Option<ir::ValueObject>)> {
    let trimmed = text.trim();
    match type_context_call_word(trimmed) {
        Some("list_of") => {
            let open = trimmed
                .find('(')
                .expect("type_context_call_word already confirmed a '('");
            let inner = trimmed[open + 1..trimmed.len() - 1].trim();
            if classify_lexical_kind(inner) != "constant" {
                return Err(Diagnostic::new(
                    file,
                    line,
                    format!("'{word}'s list_of(...) must hold a constant type name, got '{inner}'"),
                ));
            }
            Ok((inner.to_string(), true, None))
        }
        Some("one_of") => {
            let open = trimmed
                .find('(')
                .expect("type_context_call_word already confirmed a '('");
            let inner = &trimmed[open + 1..trimmed.len() - 1];
            let values: Vec<String> = ruby_value::split_items(inner)
                .into_iter()
                .map(|segment| match ruby_value::read(segment.trim()) {
                    ruby_value::Value::Str(s) => s,
                    other => ruby_value::to_s(&other),
                })
                .collect();
            if values.is_empty() {
                return Err(Diagnostic::new(
                    file,
                    line,
                    format!("'{word}'s inline one_of(...) names no values"),
                ));
            }
            let vo = crate::build::closed_sets::synthesize(field_name, &values);
            let type_name = vo.name.clone();
            Ok((type_name, false, Some(vo)))
        }
        Some(other) => Err(Diagnostic::not_yet_implemented(
            file,
            line,
            format!("{word}'s inline {other}(...) type"),
        )),
        // A quoted type name is refused; the bare constant resolves forward references too.
        None if classify_lexical_kind(trimmed) == "text" => Err(Diagnostic::new(
            file,
            line,
            format!(
                "'{field_name}'s type {trimmed} is quoted text — give the bare constant instead"
            ),
        )),
        None => Ok((trimmed.to_string(), false, None)),
    }
}

/// Walks lines inside an open `context` up to and including the matching `end`, gating each one.
/// The first gate failure or not-yet-implemented construct, at any depth, aborts the walk.
pub fn walk_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    context: &'static str,
) -> ParseResult<()> {
    loop {
        let line = *lines.get(*pos).ok_or_else(|| {
            let last = lines.last().map(|l| l.number).unwrap_or(0);
            Diagnostic::new(
                file,
                last,
                format!("unexpected end of file — still inside {context}"),
            )
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
                .ok_or_else(|| {
                    Diagnostic::new(
                        file,
                        line.number,
                        format!(
                            "'{}' opens an undeclared context '{}'",
                            call.word, row.inner
                        ),
                    )
                })?;
            walk_body(file, lines, pos, inner_context)?;
            // The nested body gated cleanly but builds nothing yet, so the failure is reported at
            // the construct just entered rather than the outer `context`.
            Err(dispatch_stub(inner_context, file, line.number, &call.word))
        }
        Opener::BraceBlock { .. } | Opener::None => {
            Err(dispatch_stub(context, file, line.number, &call.word))
        }
    }
}
