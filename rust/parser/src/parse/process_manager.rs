//! The `ProcessManager`/`Handler` constructs
//! (`lib/hecksagain/bluebook/ir/process_manager.rb`) — shared here the
//! same way Ruby shares them (`Handler`'s builder is
//! `ProcessManagerBuilder::HandlerBuilder`, a nested class, not a
//! standalone one — see `spec/syntax_conformance_spec.rb`'s `BUILDER`
//! table). STAGE 4: `correlates_by`/`starts_on`/`ends_on`/`state`, and
//! `on ... do |event| dispatch ... end end` handler bodies — confirmed
//! real by banking.bluebook's own three sagas (`Settlement`,
//! `ExternalSettlement`, `Onboarding`). `Onboarding`'s own
//! `on "OnboardingDeclined", transition: {...}` (NO `do ... end` at
//! all — `ProcessManagerBuilder#on`'s block is optional) is the real
//! grammar gap Stage 4 found: `syntax.bluebook` carried only the
//! `body: "keywords"` row for `on`/`ProcessManager` before this stage,
//! the same "one word, two bodies" shape `identified_by` already
//! carries two rows for — fixed by adding the sibling `body: "none"`
//! row rather than guessed around in this parser.
//!
//! `saga`/`Saga` (the derived compensation reading, `handler_for
//! ("refused")`) is deliberately absent from `to_h` — `IR::ProcessManager
//! #to_h`'s own comment: "the IR export spells the SOURCE, and a derived
//! fact is not a fact about the source" — so nothing here needs to build
//! it; a `Vec<ProcessManagerHandler>` already carries everything `saga`
//! would derive from.

use super::{ArgumentGateResult, GatedLine};
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{Opener, SourceLine};
use crate::ruby_value;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("ProcessManager.{word}"))
}

/// Parses a `process_manager "Name" do ... end` body.
pub fn parse_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str) -> ParseResult<ir::ProcessManager> {
    let mut pm = ir::ProcessManager { name: name.to_string(), ..Default::default() };

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "ProcessManager")? else {
            return Ok(pm);
        };
        let line = gated.line.number;

        match gated.row.word {
            // `ProcessManagerBuilder#correlates_by(field) = @correlates_by
            // = field.to_sym` — a DOTTED symbol, so `positional_symbol`'s
            // own quoted-spelling handling (`:"reference.value"`) is what
            // this needs; a bare identifier could never spell the dot at
            // all.
            "correlates_by" => pm.correlates_by = super::positional_symbol(file, line, "correlates_by", &gated.args, 1)?,
            "starts_on" => pm.starts_on = Some(super::positional_text(file, line, "starts_on", &gated.args, 1)?),
            "ends_on" => pm.ends_on = Some(super::positional_text(file, line, "ends_on", &gated.args, 1)?),
            "state" => pm.states.push(super::positional_text(file, line, "state", &gated.args, 1)?),
            "on" => pm.handlers.push(parse_handler(file, lines, pos, line, &gated)?),
            _ => return Err(super::not_built_yet("ProcessManager", gated.row, file, line, &gated.call.word)),
        }
    }
}

/// `ProcessManagerBuilder#on(event_type, transition:, &block)` — the
/// event_type argument is EITHER a `text` (an announced event name,
/// `"TransferRequested"`) or a `symbol` (the `:refused` sentinel —
/// `IR::ProcessManager::REFUSED`, a leg noticing a dispatch it made was
/// declined, which no aggregate ever announces) — BOTH already gated by
/// `syntax.bluebook`'s own two Argument rows for `on`/`ProcessManager`,
/// so this only has to read whichever one the text turned out to be,
/// `.to_s`-equivalent either way (`ir::ProcessManagerHandler.event_type`
/// is a bare String regardless of which spelling wrote it).
///
/// `transition: { "requested" => "requested" }` is a single `pairs_shape:
/// "fields"` argument — `argument_gate`'s own `"=>"`-keyed named entry,
/// the SAME shape `Lifecycle::transition`'s own `from`/`to_state` pair
/// uses — split into `from_state`/`to_state` here.
///
/// The block is OPTIONAL (`Opener::None` is legal — this module's own
/// header names the real grammar gap that admits it) — an empty
/// `dispatches` list when absent, the nested `Handler` body's own
/// `dispatch` lines collected when present.
fn parse_handler(file: &str, lines: &[SourceLine], pos: &mut usize, line: usize, gated: &GatedLine<'_>) -> ParseResult<ir::ProcessManagerHandler> {
    let event_type = event_type_text(file, line, &gated.args)?;
    let (from_state, to_state) = transition_pair(file, line, &gated.args)?;

    let dispatches = match &gated.call.opener {
        Opener::None => Vec::new(),
        Opener::DoBlock { .. } => parse_dispatches(file, lines, pos)?,
        Opener::BraceBlock { .. } => unreachable!("body_gate never admits a BraceBlock for 'on'/ProcessManager"),
    };

    Ok(ir::ProcessManagerHandler { event_type, from_state, to_state, dispatches })
}

fn event_type_text(file: &str, line: usize, args: &ArgumentGateResult) -> ParseResult<String> {
    let raw = args
        .positional
        .iter()
        .find(|(idx, _)| *idx == 1)
        .map(|(_, text)| text.as_str())
        .ok_or_else(|| Diagnostic::new(file, line, "'on' names no event"))?;
    let trimmed = raw.trim();
    if let Some(name) = trimmed.strip_prefix(':') {
        // The `:refused` sentinel — quoted or bare, both spell the same
        // dotless word in practice, but reuse the same unquoting rule
        // `positional_symbol` uses for consistency.
        return Ok(if name.len() >= 2 && name.starts_with('"') && name.ends_with('"') { ruby_value::unquote_for_symbol(name) } else { name.to_string() });
    }
    Ok(match ruby_value::read(trimmed) {
        ruby_value::Value::Str(s) => s,
        other => ruby_value::to_s(&other),
    })
}

fn transition_pair(file: &str, line: usize, args: &ArgumentGateResult) -> ParseResult<(String, String)> {
    let raw =
        super::named_raw(args, "transition").ok_or_else(|| Diagnostic::new(file, line, "'on' names no 'from => to' transition:"))?;
    // UNLIKE `Lifecycle::transition`'s own bare positional rocket pair
    // (`transition "X" => "Y"`), `on`'s own `transition:` is a NAMED
    // argument whose VALUE is a Ruby Hash LITERAL wrapping that same
    // pair (`transition: { "start" => "started" }`) — the argument gate
    // only special-cases a POSITIONAL (`at: "1"`) fields-pairs row (see
    // `parse::argument_gate`'s own header on why), so this named one
    // arrives here as the WHOLE brace-wrapped literal's raw text, not
    // pre-split. Strip the wrapper — the same "argument value happens to
    // be a Hash literal, unwrap before reading" shape `command.rs`'s own
    // `parse_hash_literal_pairs` already uses for `sets ..., append: {
    // ... }` — before hunting for the top-level `=>`.
    let trimmed = raw.trim();
    let pair_text = trimmed.strip_prefix('{').and_then(|s| s.strip_suffix('}')).unwrap_or(trimmed);
    let (from_raw, to_raw) = super::split_top_level_rocket(pair_text.trim());
    if to_raw.is_empty() {
        return Err(Diagnostic::new(file, line, format!("'on's transition: '{raw}' is not a 'from => to' pair")));
    }
    Ok((text_value(from_raw), text_value(to_raw)))
}

fn text_value(raw: &str) -> String {
    match ruby_value::read(raw.trim()) {
        ruby_value::Value::Str(s) => s,
        other => ruby_value::to_s(&other),
    }
}

/// The `Handler` context's own body — zero or more `dispatch` lines
/// (`HandlerBuilder#dispatch`), up to the matching `end`.
fn parse_dispatches(file: &str, lines: &[SourceLine], pos: &mut usize) -> ParseResult<Vec<ir::DispatchSpec>> {
    let mut dispatches = Vec::new();

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Handler")? else {
            return Ok(dispatches);
        };
        match gated.row.word {
            "dispatch" => {
                let command_name = super::positional_text(file, gated.line.number, "dispatch", &gated.args, 1)?;
                let with_spec = super::named_raw(&gated.args, "with")
                    .map(|raw| parse_with_pairs(raw))
                    .unwrap_or_default();
                dispatches.push(ir::DispatchSpec { command_name, with_spec });
            }
            _ => return Err(super::not_built_yet("Handler", gated.row, file, gated.line.number, &gated.call.word)),
        }
    }
}

/// `dispatch`'s own `with:` — a `pairs_shape: "verbatim"` open map,
/// already split into `(key, raw-value-text)` pairs by `argument_gate`
/// (both the `identifier: value` and hash-rocket spellings — not
/// exercised by any real `dispatch` here, every one uses plain
/// identifiers). Each value is read back through `ruby_value` and
/// re-rendered — `IR::DispatchSpec#to_h`'s own `with_spec.map { |key,
/// value| [key.to_s, IR.render_value(value)] }` — so a Symbol
/// (`:source`, an argument reference resolved at DISPATCH time, not
/// here) keeps its colon and a nested Hash literal (`{ text: "transfer
/// out" }`) renders the same pinned way `Mutation`'s own append fields
/// do.
fn parse_with_pairs(raw: &str) -> Vec<(String, String)> {
    let trimmed = raw.trim();
    let inner = trimmed.strip_prefix('{').and_then(|s| s.strip_suffix('}')).unwrap_or(trimmed);
    ruby_value::split_items(inner)
        .into_iter()
        .filter_map(|segment| super::as_named(&segment).map(|(k, v)| (k.to_string(), ruby_value::render(&ruby_value::read(v.trim())))))
        .collect()
}
