//! The `ProcessManager`/`Handler` constructs: `transition` legs with optional `dispatch` blocks.
//! `states` is derived from the legs, not declared.

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
            // A dotted symbol (`:"reference.value"`), which only `positional_symbol` can spell.
            "correlates_by" => {
                pm.correlates_by =
                    super::positional_symbol(file, line, "correlates_by", &gated.args, 1)?
            }
            // Event references keep only the bare final segment (`Naming.event_name_ref`);
            // `SagaInterpreter` matches them against a bare `event.name`.
            "starts_on" => {
                pm.starts_on = Some(super::positional_event_name_ref(
                    file,
                    line,
                    "starts_on",
                    &gated.args,
                    1,
                )?)
            }
            "ends_on" => {
                pm.ends_on = Some(super::positional_event_name_ref(
                    file,
                    line,
                    "ends_on",
                    &gated.args,
                    1,
                )?)
            }
            "transition" => {
                for handler in parse_transition(file, lines, pos, line, &gated)? {
                    // Two legs on one (event, state) pair would be picked by declaration order;
                    // mirrors `ProcessManagerBuilder#refuse_ambiguous_legs!`.
                    if let Some(earlier) = pm
                        .handlers
                        .iter()
                        .find(|h| h.event_type == handler.event_type && h.from_state == handler.from_state)
                    {
                        return Err(Diagnostic::new(
                            file,
                            line,
                            format!(
                                "{name} declares two transitions on {event:?} from {from:?} (=> {a:?} and => {b:?}) — \
                                 a leg is selected by (event, current state), so only one may answer",
                                event = handler.event_type,
                                from = handler.from_state,
                                a = earlier.to_state,
                                b = handler.to_state,
                            ),
                        ));
                    }
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

/// Every state named by a handler's `from_state` or `to_state`, in first-seen order.
/// Order matters: `begin_saga` starts a fresh instance in `pm.states.first`.
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

/// Parses `transition "Event" => "state", from: ... do ... end`; the block is optional.
///
/// The pair key is an event name or the bare `:refused` sentinel. `from:` is mandatory here,
/// and the argument gate never checks a `pairs_shape: "fields"` row, so it is refused below.
/// A `from: [...]` list expands to one handler per source state, each with the same dispatches.
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
    // Keeps only the bare final segment of a qualified constant: `SagaInterpreter#advance_saga`
    // matches `handler.event_type` against a bare `event.name`, unlike a policy's `on`.
    let event_type = crate::build::naming::event_name_ref(event_raw.trim());
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

/// `from: "a"` or `from: ["a", "b"]`; mandatory, so no `None` case unlike `Lifecycle`'s.
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

/// The `Handler` body: zero or more `dispatch` lines up to the matching `end`.
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
                // A `do ... end` block opens the "Dispatch" context for per-dispatch compensation.
                let compensates = match &gated.call.opener {
                    Opener::None => None,
                    Opener::DoBlock { .. } => {
                        parse_compensates_block(file, lines, pos)?.map(Box::new)
                    }
                    Opener::BraceBlock { .. } => unreachable!(
                        "body_gate never admits a BraceBlock for 'dispatch'/Handler"
                    ),
                };
                dispatches.push(ir::DispatchSpec {
                    command_name,
                    with_spec,
                    compensates,
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

/// The `Dispatch` body: at most one `compensates` line, shaped like `dispatch`'s own arguments.
fn parse_compensates_block(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
) -> ParseResult<Option<ir::DispatchSpec>> {
    let mut compensates = None;

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Dispatch")? else {
            return Ok(compensates);
        };
        match gated.row.word {
            "compensates" => {
                let command_name = super::positional_command_ref(
                    file,
                    gated.line.number,
                    "compensates",
                    &gated.args,
                    1,
                )?;
                let with_spec = parse_with_pairs_opt(&gated.args);
                // A compensation has no block of its own, so it is never itself compensable.
                compensates = Some(ir::DispatchSpec {
                    command_name,
                    with_spec,
                    compensates: None,
                });
            }
            _ => {
                return Err(super::not_built_yet(
                    "Dispatch",
                    gated.row,
                    file,
                    gated.line.number,
                    &gated.call.word,
                ))
            }
        }
    }
}

/// `with:` where it is optional; absent means no bindings, which both callers read as
/// "pass everything through".
pub(super) fn parse_with_pairs_opt(args: &super::ArgumentGateResult) -> Vec<(String, String)> {
    super::named_raw(args, "with")
        .map(parse_with_pairs)
        .unwrap_or_default()
}

/// Splits a `with:` open map into `(key, rendered value)` pairs.
///
/// Values round-trip through `ruby_value`, so a Symbol keeps its colon and a nested Hash renders
/// in the pinned form.
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
