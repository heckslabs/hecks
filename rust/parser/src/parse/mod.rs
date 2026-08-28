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
use crate::ir;
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
    // A RENAMED WORD ANSWERS BOTH SPELLINGS — `sets`/`then_set` is the
    // standing example (syntax.bluebook's own `was:` column, mirrored by
    // `spec/syntax_conformance_spec.rb`'s "answers every renamed word in
    // both its spellings"). Every real bluebook in the corpus, including
    // pizzas.bluebook, is still written under the OLD spelling
    // (`then_set`), so matching only `k.word == word` would refuse every
    // one of them — confirmed live, not a hypothetical gap. `k.was` is
    // never itself a live row (spec/syntax_conformance_spec.rb's "keeps
    // no renamed-away spelling as a row of its own" already guarantees
    // that), so this can never double-match two different canonical rows.
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

/// THE BODY GATE. `none`/`keywords`/`source`/`rows` must match what
/// actually follows — picks, among the word-gated candidate rows, the one
/// whose declared `body` is compatible with the `Opener` the lexer
/// actually found. `identified_by` is the standing example of why this is
/// its own gate and not folded into the word gate: the SAME word admits a
/// `source` row (`identified_by { name.value }`) and `none` rows
/// (`identified_by :name`, `identified_by PizzaName, as: :name`) in the
/// same context, and only the body that actually follows disambiguates
/// which was written.
///
/// A `do ... end` OPENER IS ALSO `source`-COMPATIBLE, AND A `{ ... }`
/// OPENER IS ALSO `keywords`/`rows`-COMPATIBLE — Ruby itself treats
/// `{ ... }` and `do ... end` as the SAME block syntax (differing only in
/// precedence, never in what a method does with the block), so this
/// crate's own choice of which body a word gets is never something the
/// AUTHOR's choice of delimiter should be allowed to change.
/// `identified_by`'s own multi-path form (governance.bluebook's
/// `RoleAssignment`/`RoleTransition`, console_settings.bluebook's
/// `StateStyle`: `identified_by do actor_id.value; role_name.value; end`)
/// is written with `do ... end` for a `source` body — but real, confirmed
/// live syntax runs the OTHER direction too:
/// `spec/fixtures/hop_chain.bluebook`'s own `value_object("Name") {
/// attribute :value, String }` writes a `keywords` body (`value_object`'s
/// own row, `body: "keywords"`) with `{ ... }`, refused outright before
/// this widening ("'value_object' was written with a `{ ... }` block
/// (expected one of: keywords)") even though it is exactly as legal as
/// the `do ... end` spelling right below it in the very same file. But
/// `syntax.bluebook` declares only ONE row per body kind per `(word,
/// context)`, not a second one per delimiter. Safe to admit
/// unconditionally in EITHER direction (not just for one word) because no
/// `(word, context)` pair in the CURRENT table declares BOTH a `source`
/// row and a `keywords`/`rows` row — confirmed by reading every `body:
/// "source"` row directly (`identified_by`/Aggregate+Entity, `given`/
/// Command, `invariant`/ValueObject, `ensures`/Command): each has at most
/// a sibling `none` row, never a `keywords`/`rows` one, so widening EITHER
/// opener's own compatibility here can never make an ALREADY-ambiguous
/// word gate on which body an opener means. If a future word ever
/// declares both, THIS widening (not the KeywordRow order) becomes the
/// tie-break — worth revisiting then, not guessed at now.
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

/// A LIVE CROSS-CHECK against the self-hosted grammar table, mirroring
/// Ruby's own `RuleReference#verify_resolves_via!` (lib/hecks/
/// bluebook/dsl/rule_reference.rb) — each of the three hand-written
/// bare-reference resolvers (`parse::aggregate::
/// try_reference_named_chapter_given`, `parse::command::
/// try_reference_named_given`, `parse::value_object::
/// try_reference_named_invariant`) calls this FIRST, naming the
/// primitive it is about to use. If `syntax.bluebook`'s own
/// `resolves_via` for this exact (word, context) pair ever names
/// something else, this is a real drift between the language's own
/// self-description and its own implementation — caught here, not
/// silently trusted.
///
/// UNLIKE THE RUBY SIDE, no bootstrapping guard is needed:
/// `keywords.rs` is a STATIC, pre-generated file
/// (`bin/project_parser_table`) that already exists complete and
/// correct before any Rust parsing code ever runs — Rust's own parser
/// never bootstraps itself the way Ruby's self-hosting does (it never
/// parses `syntax.bluebook` to build its own grammar knowledge at
/// Rust runtime; that already happened, in Ruby, at codegen time,
/// before `cargo build` ever ran). There is no circularity here to
/// gate against.
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
    // `literal` is the WIDEST kind — syntax.bluebook's own ArgumentKind
    // comment: "a default is written so its TYPE survives ... which is
    // why it is not `text`." A Hash/Array literal survives its own type
    // exactly the same way a bare number or symbol does — confirmed live:
    // `sets :toppings, append: { name: :topping, amount: :amount }`
    // (pizzas.bluebook) declares `append:` as `kind: "literal"`, and the
    // value written there is a Hash, not a scalar. Only `constant` (a
    // bareword TYPE name, e.g. `PizzaName`) is excluded — a type name is
    // never what a `literal:`-kind argument means.
    declared == "literal" && actual != "constant"
}

/// A bare `word(...)` call shape whose leading word is itself a LIVE
/// `Type`-context word (`list_of`, `one_of` — the only two `syntax.
/// bluebook` currently declares there). `list_of(Topping)` fills a
/// `kind: "constant"` argument position (an attribute's own type slot)
/// even though it is lexically a call, not a bareword — confirmed real:
/// `attribute :toppings, list_of(Topping)` (pizzas.bluebook) is refused
/// outright without this, since `list_of(Topping)` does not start with an
/// uppercase letter the way a bare constant does. Reads the SAME
/// generated `KEYWORDS` table rather than hardcoding "list_of"/"one_of"
/// as magic strings, so a future Type-context word is recognized here
/// automatically.
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
        let mut candidates: Vec<&&ArgumentRow> = rows.iter().filter(|r| r.at == at).collect();
        if candidates.is_empty() {
            // A VARIADIC positional row (`group_by`'s own `*fields` —
            // syntax.bluebook's own `Argument.variadic` column comment)
            // repeats for every position beyond its own declared `at`,
            // the same "one row spells the kind of many" shape that
            // column documents for `one_of`'s Type-context row too
            // (which never reaches this gate at all — its own repetition
            // is hand-parsed inside a nested Type-position expression,
            // `resolve_type_expression`). `group_by`'s repetition has to
            // survive THIS gate directly, since it's an ordinary
            // top-level call, hence the explicit `variadic: "true"` flag
            // rather than an inferred one.
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

/// `pairs_shape: "fields"` — exactly ONE hash-rocket pair
/// (`"Purchase" => "sold"`), contributing two named sub-fields
/// (`pair_key_fills`/`pair_value_fields`) to the record this keyword is
/// already building. Every other top-level segment must EITHER be a plain
/// named argument this word separately declares (`from:`, in `transition`'s
/// own case) OR — real, confirmed live by
/// `spec/fixtures/payments.bluebook`'s `transition from: "pending", to:
/// "received"` — Ruby's OWN `identifier: value` hash-literal shorthand for
/// THE SAME PAIR: `LifecycleBuilder#transition` (`lib/hecks/bluebook/
/// dsl/lifecycle_builder.rb`) receives one plain Hash and does not care how
/// its entries were spelled — `{"Close" => "closed"}` and `{to:
/// "received"}` are the identical Hash shape by the time Ruby's parser is
/// done, `mapping.delete(:from)` peels off `from:` either way, and
/// `mapping.each` turns the ONE remaining entry into a transition literally
/// named after whatever key was left (`:to.to_s == "to"` here — a real,
/// slightly odd-looking but byte-confirmed transition named "to", not a
/// parser bug). So an unclaimed `identifier: value` segment (not `from:`,
/// not any other row this word specifically declares) is reconstructed as
/// the equivalent `"identifier" => value` text and folds into the SAME
/// `field_pairs`/"one pair required" accounting a real rocket segment
/// would — nothing downstream (`lifecycle::parse_body`'s own
/// `named_raw(&gated.args, "=>")`) needs a second code path for it.
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

/// `pairs_shape: "verbatim"`/`"elements"` — MANY segments merged into one
/// open map (`member code: "JPY", minor_units: 0`), distinguished from a
/// more specific `named:` row (claimed individually) by not matching any
/// such row's own name.
///
/// TWO SEGMENT SHAPES, not one — `as_named`'s `identifier: value` handles
/// the common case, but a key that is not a bare identifier (a DOTTED
/// query path) cannot be spelled that way at all: Ruby itself requires a
/// quoted symbol and hash-rocket syntax for it. Confirmed real, not
/// hypothetical: `where(:"pizza.price_cents.cents" => { lt: :ceiling })`
/// (pizzas.bluebook's own `CostingLessThan` query) is refused outright
/// without this — `:"pizza.price_cents.cents"` starts with `:`, not an
/// identifier character, so `as_named` never matches it, and the segment
/// fell through to "bare positional argument", which `where` does not
/// admit. `has_top_level_rocket` (already used by the `pairs_shape:
/// "fields"` branch above) is reused here for the same reason it exists
/// there: the two spellings never overlap, so no segment is ever
/// ambiguous between them.
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

/// The FIELD NAME a `where`/`member` pair's own key names — a bare or
/// quoted Ruby Symbol literal (`:status`, `:"pizza.price_cents.cents"`).
/// This language's pairs-argument keys are always symbols (never a
/// string, never a bareword), so anything else is a real refusal, not a
/// guess.
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

/// Maps a `KeywordRow.inner` context name (the body the word opens) to the
/// per-construct module responsible for it, per the same BUILDER grouping
/// `spec/syntax_conformance_spec.rb` already uses (`OneOf` shares
/// `ValueObjectBuilder`, `Handler` shares `ProcessManagerBuilder`,
/// `PortOperation` shares `DomainPortBuilder`).
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
        other => Diagnostic::not_yet_implemented(
            file,
            line,
            format!("{other}.{word} (unmapped inner context)"),
        ),
    }
}

/// The honest fallback for a WORD this parser doesn't (yet) build real IR
/// for — reused by every Stage-2 construct parser (aggregate.rs,
/// command.rs, ...) for whatever slice of its own grammar pizzas.bluebook
/// doesn't exercise, so an unimplemented word fails with the EXACT same
/// diagnostic Stage 1's own generic `walk_body`/`dispatch_stub` already
/// produced — `tests/gates.rs`'s still-Stage-1 fixtures (entity.bluebook,
/// read_model.bluebook, process_manager.bluebook) depend on this wording
/// staying stable across the two code paths.
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

/// ONE GATED LINE — shape, word, body, and argument gates all already
/// run for real (see this module's own header), returned WITHOUT
/// consuming any nested body a `do`/`{` opener might introduce; the
/// caller (a `parse::<construct>::parse_body` function) decides whether
/// it implements that nested construct and, if so, recurses itself. This
/// is the Stage 2 REPLACEMENT for `handle_call` above for constructs this
/// crate now actually builds IR for. STAGE 8: `handle_call`/`walk_body`
/// are no longer called by anything — `main.rs::run_resolve` (their
/// last real caller) now builds real IR too
/// (`parse::chapter::resolve_uses_framework`), and every fixture
/// `tests/gates.rs` still exercises through the generic gate goes
/// through `not_built_yet`/`next_line` above instead. Left in place
/// (genuinely dead, `#[warn(dead_code)]`-flagged) rather than deleted —
/// a pure cleanup with no behavior change, out of this stage's own scope.
pub(crate) struct GatedLine<'src> {
    pub line: SourceLine<'src>,
    pub call: Call,
    // Always `'static` regardless of the source text's own lifetime —
    // every `KeywordRow` lives in the GENERATED `keywords::KEYWORDS`
    // slice, which is itself `'static`.
    pub row: &'static KeywordRow,
    pub args: ArgumentGateResult,
}

/// Reads and gates the next line inside `context`, from `*pos`. `None`
/// means `end` was found (and consumed) — the body is over. `Some` means
/// a legal call was found (shape/word/body/argument gates all passed);
/// `*pos` has advanced past the line ITSELF, never past any nested body.
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

/// The N'th (1-based) positional argument's raw captured text, or a gate
/// failure if it's missing — used only after `argument_gate` has already
/// confirmed a required positional at that index exists, so the "missing"
/// branch here is a defensive `unreachable`-shaped error, never actually
/// hit by a well-formed call.
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

/// A required TEXT (quoted-string) positional argument, unquoted —
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

/// A required SYMBOL positional argument, stripped of its leading colon —
/// `attribute :name`, `sets :toppings`, `order_by :name`. Handles BOTH
/// bare (`:name`) and quoted (`:"a.b"`) spellings — the quoted form is
/// real, dotted-path syntax a bare identifier cannot spell
/// (`correlates_by :"reference.value"`, `process_manager`'s own required
/// scalar correlation key — `ProcessManagerBuilder#validate!`'s own
/// comment on why the dot is mandatory).
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

/// The bare name out of a symbol TOKEN as WRITTEN in source — `:name` ->
/// `name`, `:"a.b"` -> `a.b`. Distinct from `ruby_value::read`, which
/// reads back a Symbol from a RENDERED wire value (`Literal.render`'s own
/// output) rather than source syntax; the two never overlap, but neither
/// alone covers what a `kind: "symbol"` argument may actually look like
/// at the syntax layer.
fn symbol_text(raw: &str) -> Option<String> {
    let rest = raw.strip_prefix(':')?;
    if rest.len() >= 2 && rest.starts_with('"') && rest.ends_with('"') {
        Some(ruby_value::unquote_for_symbol(rest))
    } else {
        Some(rest.to_string())
    }
}

/// A CONSTANT (bareword type name) positional argument, raw — `attribute
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

/// A COMMAND-REFERENCE positional argument — `trigger Account::Debit`
/// (a bare command constant, `kind: "constant"`) or the LEGACY quoted
/// spelling `trigger "Account.Debit"` (`kind: "text"`, still accepted by
/// Ruby under `MetaValidator.shadow_parsing?`) — both declared as
/// argument rows for the SAME `fills` slot (`trigger`'s own
/// `trigger_command`, `dispatch`'s own `command_name`), so `argument_
/// gate` already admits either lexical shape here; this just derives the
/// same text `Hecks::Naming.command_ref` derives from whichever one
/// was written.
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

/// A PROCESS MANAGER'S OWN EVENT-REFERENCE positional argument —
/// `starts_on Transfer::TransferRequested` / `ends_on Transfer::
/// TransferSettled` (a bare event constant, `kind: "constant"`) or the
/// legacy quoted spelling (`kind: "text"`) — both declared as argument
/// rows for the same `fills` slot, same as `positional_command_ref`
/// above, but derives `Hecks::Naming.event_name_ref` instead of
/// `Naming.event_ref`: that method's own header explains why a process
/// manager's own event references keep only their bare final segment
/// rather than being rejoined with `.`.
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

/// A NAMED argument's raw captured text, if the call gave one —
/// `as: :name`, `optional: true`, `to: "sold"`.
pub(crate) fn named_raw<'a>(args: &'a ArgumentGateResult, name: &str) -> Option<&'a str> {
    args.named
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, v)| v.as_str())
}

/// A NAMED CONSTANT argument — `to: Payment`. Same shape as
/// `positional_constant`: raw captured text, trimmed, no further
/// coercion — a bareword's target name is resolved downstream
/// (`naming::demodulise`), never here.
pub(crate) fn named_constant<'a>(args: &'a ArgumentGateResult, name: &str) -> Option<&'a str> {
    named_raw(args, name).map(|s| s.trim())
}

/// A NAMED SYMBOL argument, stripped of its leading colon — `as: :name`.
/// See `positional_symbol`'s own comment on `symbol_text` — same
/// bare-or-quoted handling, named-argument side.
pub(crate) fn named_symbol(args: &ArgumentGateResult, name: &str) -> Option<String> {
    named_raw(args, name).and_then(|raw| symbol_text(raw.trim()))
}

/// A NAMED TEXT argument, unquoted — none of pizzas.bluebook's own named
/// arguments happen to be plain quoted text (every `text`-kind named
/// argument the corpus uses is `pattern:`/`admits:`, neither exercised),
/// kept for the same completeness `build/naming.rs` documents elsewhere.
pub(crate) fn named_text(args: &ArgumentGateResult, name: &str) -> Option<String> {
    named_raw(args, name).map(|raw| match ruby_value::read(raw) {
        ruby_value::Value::Str(s) => s,
        other => ruby_value::to_s(&other),
    })
}

/// A NAMED FLAG (`true`/`false`) argument — `optional: true`.
pub(crate) fn named_flag(args: &ArgumentGateResult, name: &str) -> bool {
    named_raw(args, name)
        .map(|raw| raw.trim() == "true")
        .unwrap_or(false)
}

/// `AttributeCollector#attribute` (attribute_collector.rb) — shared by
/// every context that admits a bare `attribute` line (Aggregate, Command,
/// ValueObject, Query, PortOperation — the SAME shape, per
/// `spec/syntax_conformance_spec.rb`'s own reading of `attribute`'s
/// declared rows). Position 2 (the type) defaults to `String` when
/// absent, matching `attribute(name, type = String, ...)`'s own Ruby
/// default.
///
/// Returns the attribute alongside an OPTIONAL synthesized closed-set
/// value object (`Some` only when the type position was an inline
/// `one_of(...)`) — see `resolve_type_expression`'s own header for why
/// this is always RETURNED but only sometimes KEPT: only
/// `parse::aggregate`'s own caller folds it into the owning aggregate's
/// `value_objects`; every other caller (`parse::command`/`parse::query`/
/// `parse::value_object`/`parse::domain_port`) discards it, mirroring
/// `AttributeCollector#synthesise_closed_set`'s own callers exactly
/// (`build/closed_sets.rs`'s own header names each one by name).
/// The RAW text of a `source`-shaped body, regardless of which of the two
/// legal spellings wrote it — `{ ... }` (`Opener::BraceBlock`, already
/// captured by the lexer at classify-time) or `do ... end`
/// (`Opener::DoBlock`, needing `lex::capture_do_block_body` to consume
/// the raw lines up to the matching `end` — `body_gate`'s own comment
/// explains why BOTH are legal for the same declared `source` row).
/// Shared by every `source`-shaped word this parser builds real IR for —
/// `identified_by`'s block form (`parse::aggregate`), `given`
/// (`parse::command`), `invariant` (`parse::value_object`) — so a future
/// one (`ensures`) gets the identical two-spelling handling for free.
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

/// Dispatches a NESTED `keywords`/`rows` body to `parse`, regardless of
/// which of the two legal block delimiters wrote it — `do ... end`
/// (`Opener::DoBlock`, whose body already lives in `lines`/`*pos` as
/// ordinary physical lines, closed by a real `end` line the caller's own
/// `next_line`/`walk_body` loop already knows how to find) or `{ ... }`
/// (`Opener::BraceBlock`, captured whole on the SAME physical line as the
/// opening call, real and confirmed live:
/// `spec/fixtures/hop_chain.bluebook`'s own `value_object("Name") {
/// attribute :value, String }` — `body_gate`'s own widening, this file's
/// header, already lets either delimiter reach a `keywords`/`rows` row,
/// but every per-construct `parse_body` function (`value_object::
/// parse_body` etc.) walks `(lines, pos)` directly and knows nothing
/// about `Opener` at all). This is the ONE place that difference gets
/// absorbed — a `BraceBlock`'s captured text is split into synthetic
/// one-statement-per-line `SourceLine`s (`brace_body_statements`, below)
/// terminated by a synthetic `"end"`, so `parse` never needs its own
/// second code path for it, and every OTHER construct that grows this
/// same need later reuses this unchanged.
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

/// A captured `{ ... }` body's raw text, split into one statement per
/// top-level (not inside quotes/braces/brackets/parens) `;` — real Ruby
/// allows `;`-separated statements on one physical line inside a block,
/// and a single-line `{ ... }` body has no OTHER way to hold more than
/// one. Only the one-statement case is exercised by any real corpus
/// member today (`value_object("Name") { attribute :value, String }`),
/// but the general form costs nothing extra to build correctly alongside
/// it — the same reasoning `lifecycle::from_values`'s own header gives
/// for building `transition ... from: [...]`'s list form unexercised.
/// Ends with a synthetic `"end"` so `parse_nested_body`'s caller — built
/// entirely around "a body ends at a literal `end` line" — needs no
/// separate termination rule for this shape.
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

/// DEFERRED CONSTRUCTION — the Rust-side equivalent of `AggregateBuilder`/
/// `EntityBuilder`'s own `@pending_entities`/`@pending_commands`/
/// `@pending_queries` + `#drain_pending!` (Ruby, `dsl/aggregate_builder.rb`/
/// `dsl/entity_builder.rb`). Ruby QUEUES an unevaluated block and only
/// `instance_eval`s it later, once the owning aggregate/entity's own
/// `instance_eval` has fully finished — so a nested `entity`/`command`/
/// `query`'s own resolution logic (an entity's `identified_by` single-
/// field-value-object auto-unwrap, a command's `sets :list, append:
/// {...}` element-type lookup against a SIBLING entity, a command's own
/// bare `given(...)` precondition reference) sees the owner's COMPLETE
/// `value_objects`/`entities`/`preconditions`, not just whatever was
/// declared textually before that line.
///
/// Rust has no unevaluated block to defer — `entity`/`command`/`query`
/// are `keywords`-shaped bodies, walked line-by-line straight out of
/// `lines`/`*pos`. The equivalent move: on hitting one of these three
/// words, DON'T recurse into the body yet. Record where it starts
/// (`body_start`) and, for a `do ... end` opener, SKIP past it —
/// `lex::capture_do_block_body` (already used elsewhere to CAPTURE a
/// `source`-shaped body's raw text) does exactly the "purely textual
/// do/end depth tracking" this needs, reused here just to advance `*pos`
/// past the block without interpreting it; its own returned text is
/// discarded. A `{ ... }` opener needs no skip at all — `body` is
/// already the whole captured text, on the one physical line the
/// opening call itself was on, so `*pos` is already correct.
///
/// The real parse happens later, via `build_deferred`, once the owner's
/// own top-level line-range has been walked in full and its
/// `value_objects`/`entities`/`preconditions`/`attributes` are the real,
/// final lists — not a snapshot mid-walk.
pub(crate) struct PendingBody {
    opener: Opener,
    line_number: usize,
    body_start: usize,
}

/// Called the instant `entity`/`command`/`query`'s own OPENING line has
/// been gated (`*pos` already past that line) — see `PendingBody`'s own
/// header. `opener`/`line_number` come off that same gated line.
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

/// The drained counterpart of `defer_body` — parses a deferred body for
/// real, dispatching through the SAME `parse_nested_body` every other
/// `keywords`/`rows`-body construct already uses (so a `{ ... }`-opened
/// entity/command/query gets the identical synthetic-line treatment
/// `value_object`'s own arm does, with no second code path). `lines`
/// must be the SAME slice `defer_body` was called against — `body_start`
/// is an index into it, meaningless against any other.
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

/// The `identified_by` forms this parser actually resolves/refuses —
/// shared by `parse::aggregate` and `parse::entity`, since
/// `AttributeCollector#resolve_identity_field!`/`#resolve_identity_type!`
/// is the SAME module both `AggregateBuilder` and `EntityBuilder`
/// include, and `EntityBuilder#identified_by` is (per its own comment)
/// `AggregateBuilder`'s method line for line. See
/// `build/identity.rs`'s own header for why the TYPE form is a
/// DERIVATION while `Paths` (the SOURCE-shaped block form, either
/// spelling) is not: its body already IS the identity, captured raw and
/// canonicalized, never resolved against already-declared attributes.
/// `Fields` is the LIVE form (ADR 0025) — one or more bare symbols,
/// each resolved against its own already-declared attribute at
/// `build/identity.rs::resolve_identity_field`.
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

/// `AggregateBuilder#identified_by`/`EntityBuilder#identified_by` — the
/// THREE forms Ruby's own single method distinguishes: a bareword
/// starting uppercase is a value object (the LEGACY TYPE form,
/// `identified_by PizzaName, as: :name`, `Opener::None`); one or more
/// starting lowercase are Symbols, the FIELD form (`identified_by
/// :field, :field_two`, `Opener::None`, VARIADIC — syntax.bluebook's own
/// `identified_by` argument row, `variadic: "true"`, the same column
/// `group_by`'s does); a BLOCK — spelled either `identified_by { ... }`
/// (`Opener::BraceBlock`) or `identified_by do ... end`
/// (`Opener::DoBlock`) — is a real `ValueObject` body. Its deterministic
/// type name is supplied by the aggregate/entity caller and the resulting
/// value object is installed in the owning aggregate during resolution.
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

/// The bare name out of a positional symbol TOKEN, already known (by the
/// generic argument gate's own `kind_matches` check) to be `kind:
/// "symbol"` — a thin wrapper over `symbol_text` for a caller iterating
/// `args.positional` directly rather than through `positional_symbol`'s
/// own single-index lookup (VARIADIC — `identified_by` may take any
/// number, so there is no single `at` to ask for).
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

pub(crate) fn build_attribute(
    file: &str,
    line: usize,
    word: &str,
    args: &ArgumentGateResult,
) -> ParseResult<(ir::Attribute, Option<ir::ValueObject>)> {
    let name = positional_symbol(file, line, word, args, 1)?;
    // THE TYPE POSITION IS ALWAYS A BARE CONSTANT, ALWAYS REQUIRED (S3,
    // ADR 0025) — no mint default, refused rather than silently filled
    // with "String".
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
    // `AttributeCollector#attribute`'s own `refuse_unshared_pattern(name,
    // pattern) if pattern` — called BEFORE the attribute is built, at
    // declaration time, exactly the fail-closed spot Ruby itself refuses
    // in. Confirmed real: banking.bluebook's own `EmailAddress` value
    // object declares a pattern that MUST pass this (spelled with
    // explicit ranges for exactly this reason, per its own comment).
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

/// An attribute's own TYPE POSITION — almost always a bare constant
/// (`Pizza`, `Integer`), but `list_of(Topping)` is real, exercised
/// syntax (pizzas.bluebook's own `attribute :toppings, list_of(Topping)`)
/// that reads as a CALL, not a bareword. `type_context_call_word` already
/// widened `classify_lexical_kind` to accept this at the argument-gate
/// level; this is where the call actually gets unwrapped into
/// `(inner_type, list: true)`.
///
/// `one_of(...)` is the type-position's other live word (same `Type`
/// context) — STAGE 3: real, confirmed by console_settings.bluebook's
/// own `StateStyle.tone`/`Collection.identity_strategy`
/// (`attribute :tone, one_of("good", "warn", "danger", "muted",
/// "accent"), optional: true`). Desugars exactly like
/// `AttributeCollector#synthesise_closed_set`: the field's own name
/// (`field_name`) becomes the synthesized value object's Pascal-cased
/// name (`build/closed_sets.rs`), and the attribute's own type is that
/// name — the VALUE OBJECT itself is handed back to the caller, which
/// decides whether to keep it (see `build_attribute`'s own header).
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
        // THE QUOTED-TEXT FORM IS GONE (S3, ADR 0025 — "the type position
        // takes a bare constant, always required"). It existed only as a
        // forward-reference workaround (`attribute :name, "Name"`, ahead
        // of `value_object("Name") do ... end` declared later in the same
        // aggregate) — `ConstShim`'s S0b bridge already resolves a bare,
        // not-yet-declared constant identically, so the workaround is
        // redundant. Not era-locked (checked directly, live and frozen
        // corpus alike), so refused outright rather than kept for a
        // shadow-parse Rust never runs anyway.
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
            // The ENTIRE nested body (`inner_context`) gated successfully
            // with no leaf construct left unimplemented inside it — still
            // not implemented at Stage 1 (build/*.rs and ir.rs are stubs,
            // see their own headers), so the construct JUST RECURSED INTO
            // is the honest failure point, not the outer `context` that
            // merely opened it.
            Err(dispatch_stub(inner_context, file, line.number, &call.word))
        }
        Opener::BraceBlock { .. } | Opener::None => {
            Err(dispatch_stub(context, file, line.number, &call.word))
        }
    }
}
