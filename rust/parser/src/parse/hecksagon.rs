//! The `Hecksagon` construct: a `.hecksagon` file's `port` blocks and `uses_framework` words.
//! Adapter binds (`persisted_by`, `projected_by`, `subscribe`) are shape-matched and dropped.

use super::domain_port;
use super::policy;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{self, LineShape, Opener, SourceLine};

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Hecksagon.{word}"))
}

/// Applies a `.hecksagon` body onto an already-built `ir::Bluebook`, attaching
/// aggregate-scoped ports to the aggregates the sibling `.bluebook` registered.
///
/// `uses_framework_names` and `vendored_bluebook_names` collect each argument in file order
/// for `hecks-parse resolve`; `ir.json` itself carries neither.
///
/// `require_matching_aggregate` is `false` for resolve, which never sees a `.bluebook`, so an
/// aggregate-scoped `port` skips the attach step instead of failing the lookup.
pub fn apply(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    bluebook: &mut ir::Bluebook,
    uses_framework_names: &mut Vec<String>,
    vendored_bluebook_names: &mut Vec<String>,
    require_matching_aggregate: bool,
) -> ParseResult<()> {
    loop {
        let line = *lines.get(*pos).ok_or_else(|| {
            let last = lines.last().map(|l| l.number).unwrap_or(0);
            Diagnostic::new(
                file,
                last,
                "unexpected end of file — still inside Hecksagon",
            )
        })?;

        if line.text == "end" {
            *pos += 1;
            return Ok(());
        }

        if let Some((receiver, rest)) = lex::strip_aggregate_receiver(line.text) {
            *pos += 1;
            apply_aggregate_qualified(
                file,
                lines,
                pos,
                line.number,
                receiver,
                rest,
                bluebook,
                require_matching_aggregate,
            )?;
            continue;
        }

        // Bare root adapter-bind (`persisted_by "Heki"`): any word outside Hecksagon's closed
        // words is shape-matched and dropped, bypassing the closed-vocabulary `word_gate`.
        if let LineShape::Call(call) = lex::classify(file, &line)? {
            if !matches!(
                call.word.as_str(),
                "port" | "subscribe" | "uses_framework" | "uses_embryonaut_bluebook" | "translates" | "bounded" | "end"
            ) {
                *pos += 1;
                if matches!(call.opener, Opener::DoBlock { .. }) {
                    skip_dropped_body(file, lines, pos)?;
                }
                continue;
            }
        }

        match super::next_line(file, lines, pos, "Hecksagon")? {
            None => return Ok(()),
            Some(gated) => match gated.row.word {
                // A bare root port belongs to the chapter, not an aggregate; validated, then
                // discarded (`IR::Bluebook#to_h` has no `ports:` key).
                "port" => {
                    let name =
                        super::positional_text(file, gated.line.number, "port", &gated.args, 1)?;
                    let _ = domain_port::parse_body(file, lines, pos, &name, None)?;
                }
                // A cross-domain reaction wired here instead of the `.bluebook`; builds the same
                // `ir::Policy`, pushed after every policy the sibling file contributed.
                "translates" => {
                    let name = super::positional_text(
                        file,
                        gated.line.number,
                        "translates",
                        &gated.args,
                        1,
                    )?;
                    let built = policy::parse_body(file, lines, pos, &name)?;
                    bluebook.policies.push(built);
                }
                // Gated, then collected; `ir.json` carries no `uses_framework` key.
                "uses_framework" => {
                    uses_framework_names.push(super::positional_text(
                        file,
                        gated.line.number,
                        "uses_framework",
                        &gated.args,
                        1,
                    )?);
                }
                // Collected like `uses_framework`; a binding fact, absent from `ir.json`.
                "uses_embryonaut_bluebook" => {
                    vendored_bluebook_names.push(super::positional_text(
                        file,
                        gated.line.number,
                        "uses_embryonaut_bluebook",
                        &gated.args,
                        1,
                    )?);
                }
                "subscribe" => {}
                // Consumer-owned bounded-context mark; a wiring fact, dropped like `subscribe`.
                "bounded" => {}
                _ => {
                    return Err(super::not_built_yet(
                        "Hecksagon",
                        gated.row,
                        file,
                        gated.line.number,
                        &gated.call.word,
                    ))
                }
            },
        }
    }
}

/// `<Domain>::<Aggregate>.<verb>`: `port` attaches a port to the named aggregate; any other
/// verb is a generic adapter-bind, shape-matched and dropped.
fn apply_aggregate_qualified(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    line_number: usize,
    receiver: &str,
    rest: &str,
    bluebook: &mut ir::Bluebook,
    require_matching_aggregate: bool,
) -> ParseResult<()> {
    let synthetic = SourceLine {
        number: line_number,
        text: rest,
    };
    let shape = lex::classify(file, &synthetic)?;
    let call = match shape {
        LineShape::Call(call) => call,
        LineShape::End => {
            return Err(Diagnostic::new(
                file,
                line_number,
                "unexpected 'end' right after an aggregate-qualified receiver",
            ))
        }
    };

    if call.word != "port" {
        if matches!(call.opener, Opener::DoBlock { .. }) {
            skip_dropped_body(file, lines, pos)?;
        }
        return Ok(());
    }

    let candidates = super::word_gate(file, "port", "Hecksagon", line_number)?;
    let row = super::body_gate(file, &candidates, &call.opener, line_number, "port")?;
    let args = super::argument_gate(file, row.word, "Hecksagon", &call.args, line_number)?;
    let port_name = super::positional_text(file, line_number, "port", &args, 1)?;

    let aggregate_name = receiver.rsplit("::").next().unwrap_or(receiver);
    let built = domain_port::parse_body(file, lines, pos, &port_name, Some(aggregate_name))?;

    let found = bluebook
        .aggregates
        .iter_mut()
        .find(|a| a.name == aggregate_name);
    match found {
        Some(aggregate) => aggregate.ports.push(built),
        None if require_matching_aggregate => {
            return Err(Diagnostic::new(
                file,
                line_number,
                format!("{receiver} declares no such aggregate — a port needs one to belong to"),
            ));
        }
        // Resolve's accumulator has no aggregates; the body was gated, so there is nothing to
        // attach.
        None => {}
    }
    Ok(())
}

/// Skips a dropped adapter-bind's `do ... end` body, depth-tracked through the shape gate so
/// a malformed line inside still refuses.
fn skip_dropped_body(file: &str, lines: &[SourceLine], pos: &mut usize) -> ParseResult<()> {
    let mut depth = 1;
    while depth > 0 {
        let line = *lines.get(*pos).ok_or_else(|| {
            let last = lines.last().map(|l| l.number).unwrap_or(0);
            Diagnostic::new(
                file,
                last,
                "unexpected end of file while skipping a dropped adapter-bind body",
            )
        })?;
        *pos += 1;

        if line.text == "end" {
            depth -= 1;
            continue;
        }

        if let LineShape::Call(call) = lex::classify(file, &line)? {
            if matches!(call.opener, Opener::DoBlock { .. }) {
                depth += 1;
            }
        }
    }
    Ok(())
}
