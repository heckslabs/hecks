//! The `ProcessManager`/`Handler` constructs
//! (`lib/hecks/bluebook/ir/process_manager.rb`) — shared here the
//! same way Ruby shares them (`Handler`'s builder is
//! `ProcessManagerBuilder::HandlerBuilder`, a nested class, not a
//! standalone one — see `spec/syntax_conformance_spec.rb`'s `BUILDER`
//! table).
//!
//! S7 (ADR 0025, "events and reactions"): ONE state-machine vocabulary —
//! the SAME `transition` word `Lifecycle`'s own `transition` already
//! carries under `context: "Aggregate"`/`"Entity"`
//! (`rust/parser/src/parse/lifecycle.rs`), one level over. The old
//! `state "x"` word (declaring states by hand) and `on event_type,
//! transition: {...} do ... end` (a NAMED `transition:` kwarg wrapping a
//! second Hash) are BOTH gone, replaced by a bare rocket-pair `transition
//! "AccountDebited" => "awaiting_credit", from: "requested" do ... end` —
//! the identical `pairs_shape: "fields"` positional argument shape
//! Lifecycle's own `transition` uses, PLUS a mandatory `from:` (Lifecycle's
//! own is optional — an aggregate transition may be admitted from any
//! state; `SagaInterpreter#advance_saga`'s own admission checks a saga
//! instance's CURRENT state by plain equality, so an unconstrained PM
//! transition would silently match nothing — refused here instead) PLUS
//! an optional dispatch block (Lifecycle's own transition never dispatches
//! anything).
//!
//! `states` is DERIVED from the transitions that name them
//! (`derived_states`, below) — the same reading `Behaviour::Lifecycle
//! #states` already gives an aggregate's own field
//! (`ProcessManagerBuilder#derived_states`) — first-seen order, walking
//! each expanded handler's own `from_state`/`to_state`.
//!
//! The IR wire shape (`ir::ProcessManager`'s own `states`/`handlers`,
//! `ir::ProcessManagerHandler`'s own `event_type`/`from_state`/`to_state`/
//! `dispatches`) is BYTE-IDENTICAL to before this slice — only how the
//! DECLARATION reaches that same shape changed, confirmed against the
//! Ruby source (`lib/hecks/bluebook/process_manager.rb`, unchanged by
//! S7) and the builder (`lib/hecks/bluebook/dsl/process_manager_
//! builder.rb`, which EXPANDS a `from: [...]` transition into several flat
//! handler rows immediately, before constructing the IR object — mirrored
//! here the same way, in `parse_transition` below).
//!
//! `saga`/`Saga` (the derived compensation reading, `handler_for
//! ("refused")`) is deliberately absent from `to_h` — `IR::ProcessManager
//! #to_h`'s own comment: "the IR export spells the SOURCE, and a derived
//! fact is not a fact about the source" — so nothing here needs to build
//! it; a `Vec<ProcessManagerHandler>` already carries everything `saga`
//! would derive from.

use super::GatedLine;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{Opener, SourceLine};
use crate::ruby_value;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("ProcessManager.{word}"))
}

/// Parses a `process_manager "Name" do ... end` body.
pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
) -> ParseResult<ir::ProcessManager> {
    let mut pm = ir::ProcessManager {
        name: name.to_string(),
        ..Default::default()
    };

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "ProcessManager")? else {
            pm.states = derived_states(&pm.handlers);
            return Ok(pm);
        };
        let line = gated.line.number;

        match gated.row.word {
            // `ProcessManagerBuilder#correlates_by(field) = @correlates_by
            // = field.to_sym` — a DOTTED symbol, so `positional_symbol`'s
            // own quoted-spelling handling (`:"reference.value"`) is what
            // this needs; a bare identifier could never spell the dot at
            // all.
            "correlates_by" => {
                pm.correlates_by =
                    super::positional_symbol(file, line, "correlates_by", &gated.args, 1)?
            }
            "starts_on" => {
                pm.starts_on = Some(super::positional_text(
                    file,
                    line,
                    "starts_on",
                    &gated.args,
                    1,
                )?)
            }
            "ends_on" => {
                pm.ends_on = Some(super::positional_text(
                    file,
                    line,
                    "ends_on",
                    &gated.args,
                    1,
                )?)
            }
            "transition" => {
                for handler in parse_transition(file, lines, pos, line, &gated)? {
                    pm.handlers.push(handler);
                }
            }
            _ => {
                return Err(super::not_built_yet(
                    "ProcessManager",
                    gated.row,
                    file,
                    line,
                    &gated.call.word,
                ))
            }
        }
    }
}

/// DERIVED, not declared (S7) — every state this procedure ever runs on is
/// already named by some handler's own `from_state` or `to_state`; a state
/// nothing transitions into or out of is not a state this procedure has,
/// the same reading `Behaviour::Lifecycle#states` already gives an
/// aggregate's own field. FIRST-SEEN ORDER, walking declaration order —
/// `begin_saga`'s own `pm.states.first` is what a fresh instance starts
/// in, so the order has to survive the derivation, not just the
/// membership.
fn derived_states(handlers: &[ir::ProcessManagerHandler]) -> Vec<String> {
    let mut states = Vec::new();
    for handler in handlers {
        for state in [&handler.from_state, &handler.to_state] {
            if !state.is_empty() && !states.contains(state) {
                states.push(state.clone());
            }
        }
    }
    states
}

/// `ProcessManagerBuilder#transition(mapping, &block)` — a bare rocket-pair
/// argument (`transition "AccountDebited" => "awaiting_credit", from:
/// "requested" do ... end`), the SAME `pairs_shape: "fields"` shape
/// `Lifecycle::transition`'s own `command => to_state` pair uses
/// (`rust/parser/src/parse/lifecycle.rs`'s own `"transition"` arm) — the
/// pair's key is EITHER a `text` (an announced event name,
/// `"TransferRequested"`) or the bare `:refused` sentinel
/// (`IR::ProcessManager::REFUSED`, a leg noticing a dispatch it made was
/// declined, which no aggregate ever announces), both already gated by
/// `syntax.bluebook`'s two Argument rows for `transition`/`ProcessManager`
/// and both read the same way `text_value` already reads Lifecycle's own
/// pair key (`ruby_value::read` turns a bare `:refused` into
/// `Value::Symbol`, and `ruby_value::to_s` drops the colon).
///
/// UNLIKE `Lifecycle::transition`'s own `from:` (genuinely optional — an
/// aggregate transition may be admitted from any state), `from:` here is
/// MANDATORY (`ProcessManagerBuilder#transition`'s own refusal for a nil
/// `from:`) — the argument gate's generic required-check never reaches a
/// `pairs_shape: "fields"` named row (see `argument_gate_fields_pairs`'s
/// own header), so the refusal has to happen here.
///
/// ONE DECLARED TRANSITION IS SEVERAL ROWS when `from:` names more than
/// one source state — `ProcessManagerBuilder#expand`'s own comment, the
/// identical fan-out `Lifecycle`'s own `from_values` (below) already
/// performs one level over: a `ProcessManagerHandler` only ever carries a
/// single `from_state`, so a `from: [...]` transition mints one row per
/// source, each carrying the SAME dispatches.
///
/// The block is OPTIONAL (`Opener::None` is legal — `ProcessManagerBuilder
/// #transition`'s own `handler.instance_eval(&block) if block`) — an
/// empty `dispatches` list when absent, the nested `Handler` body's own
/// `dispatch` lines collected when present.
fn parse_transition(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    line: usize,
    gated: &GatedLine<'_>,
) -> ParseResult<Vec<ir::ProcessManagerHandler>> {
    let pair_text = super::named_raw(&gated.args, "=>").ok_or_else(|| {
        Diagnostic::new(file, line, "'transition' names no 'event => state' pair")
    })?;
    let (event_raw, to_state_raw) = super::split_top_level_rocket(pair_text);
    let event_type = text_value(event_raw);
    let to_state = text_value(to_state_raw);

    let from_raw = super::named_raw(&gated.args, "from").ok_or_else(|| {
        Diagnostic::new(
            file,
            line,
            format!(
                "'transition' \"{event_type}\" => \"{to_state}\" names no from: — a process manager's own admission \
                 checks a saga instance's CURRENT state exactly, so a transition with no from: would match no \
                 instance ever, silently"
            ),
        )
    })?;
    let from_states = from_values(from_raw);

    let dispatches = match &gated.call.opener {
        Opener::None => Vec::new(),
        Opener::DoBlock { .. } => parse_dispatches(file, lines, pos)?,
        Opener::BraceBlock { .. } => {
            unreachable!("body_gate never admits a BraceBlock for 'transition'/ProcessManager")
        }
    };

    Ok(from_states
        .into_iter()
        .map(|from_state| ir::ProcessManagerHandler {
            event_type: event_type.clone(),
            from_state,
            to_state: to_state.clone(),
            dispatches: dispatches.clone(),
        })
        .collect())
}

fn text_value(raw: &str) -> String {
    match ruby_value::read(raw.trim()) {
        ruby_value::Value::Str(s) => s,
        other => ruby_value::to_s(&other),
    }
}

/// `from: "requested"` (one state) or `from: ["requested", "pending"]`
/// (several, list-expanded) — the SAME two-kind shape `Lifecycle`'s own
/// `from:` rows already have (`rust/parser/src/parse/lifecycle.rs`'s own
/// `from_values`), mirrored here rather than shared directly since this
/// one has no `None` case to fold in (`from:` is mandatory, checked by
/// the caller before this ever runs).
fn from_values(raw: &str) -> Vec<String> {
    let trimmed = raw.trim();
    if trimmed.starts_with('[') && trimmed.ends_with(']') {
        return ruby_value::split_items(&trimmed[1..trimmed.len() - 1])
            .into_iter()
            .map(|item| text_value(&item))
            .collect();
    }
    vec![text_value(trimmed)]
}

/// The `Handler` context's own body — zero or more `dispatch` lines
/// (`HandlerBuilder#dispatch`), up to the matching `end`.
fn parse_dispatches(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
) -> ParseResult<Vec<ir::DispatchSpec>> {
    let mut dispatches = Vec::new();

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Handler")? else {
            return Ok(dispatches);
        };
        match gated.row.word {
            "dispatch" => {
                let command_name = super::positional_command_ref(
                    file,
                    gated.line.number,
                    "dispatch",
                    &gated.args,
                    1,
                )?;
                let with_spec = parse_with_pairs_opt(&gated.args);
                dispatches.push(ir::DispatchSpec {
                    command_name,
                    with_spec,
                });
            }
            _ => {
                return Err(super::not_built_yet(
                    "Handler",
                    gated.row,
                    file,
                    gated.line.number,
                    &gated.call.word,
                ))
            }
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
/// `with:` where it is optional — absent reads as no bindings at all,
/// which is what BOTH callers mean by leaving it off: `dispatch` sends
/// the command its declared arguments, and `trigger` forwards the
/// event's whole payload verbatim.
pub(super) fn parse_with_pairs_opt(args: &super::ArgumentGateResult) -> Vec<(String, String)> {
    super::named_raw(args, "with")
        .map(parse_with_pairs)
        .unwrap_or_default()
}

pub(super) fn parse_with_pairs(raw: &str) -> Vec<(String, String)> {
    let trimmed = raw.trim();
    let inner = trimmed
        .strip_prefix('{')
        .and_then(|s| s.strip_suffix('}'))
        .unwrap_or(trimmed);
    ruby_value::split_items(inner)
        .into_iter()
        .filter_map(|segment| {
            super::as_named(&segment).map(|(k, v)| {
                (
                    k.to_string(),
                    ruby_value::render(&ruby_value::read(v.trim())),
                )
            })
        })
        .collect()
}
