//! The `Hecksagon` construct (`lib/hecksagain/language/hecksagon.bluebook`,
//! `HecksagonBuilder`) — a `.hecksagon` file's own content: `binds`,
//! `subscriptions`, `framework_members` (`uses_framework`). Two things
//! contribute to `ir.json` per the plan's finding #5: `port ... do ... end`
//! blocks (`add_port`) and `uses_framework` (which OTHER chapters get
//! generated) — everything else (`persisted_by`, `projected_by`,
//! `subscribe`) is accepted and ignored, not built.
//!
//! The `.hecksagon` adapter-bind shape itself (`Aggregate.persisted_by(...)`,
//! `Const.verb(...)`) is one of the plan's two narrow, permanent
//! open-vocabulary escapes — shape-matched and its contents DROPPED, never
//! interpreted. Not yet implemented even as a drop at Stage 1 (see
//! parse/mod.rs's `dispatch_stub` comment on `World` for the matching
//! gap) — named here as tracked Stage 2+ work rather than guessed at.

use super::domain_port;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{self, LineShape, Opener, SourceLine};

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Hecksagon.{word}"))
}

/// Applies a `.hecksagon` file's body onto an ALREADY-BUILT `ir::Bluebook`
/// — mirrors `bin/project_rust`'s own real load order (the `.bluebook`
/// loads first and registers every aggregate; `.hecksagon` loads second
/// and mutates the registered aggregates' own `ports`, via
/// `HecksagonBuilder#port`/`BindingProxy#port` -> `IR::Aggregate#
/// add_port`). Two things ever reach `ir.json` from here (finding #5):
/// an aggregate-scoped `port ... do ... end` and `uses_framework` (not
/// exercised by pizzas.hecksagon, which declares neither a bare root
/// port nor a framework member — both still real, gated paths below).
/// Everything else (`persisted_by`, `projected_by`, `subscribe`, any
/// other adapter-bind verb) is the plan's own named open-vocabulary
/// escape: shape-matched, never interpreted, its content dropped.
pub fn apply(file: &str, lines: &[SourceLine], pos: &mut usize, bluebook: &mut ir::Bluebook) -> ParseResult<()> {
    loop {
        let line = *lines.get(*pos).ok_or_else(|| {
            let last = lines.last().map(|l| l.number).unwrap_or(0);
            Diagnostic::new(file, last, "unexpected end of file — still inside Hecksagon")
        })?;

        if line.text == "end" {
            *pos += 1;
            return Ok(());
        }

        if let Some((receiver, rest)) = lex::strip_aggregate_receiver(line.text) {
            *pos += 1;
            apply_aggregate_qualified(file, lines, pos, line.number, receiver, rest, bluebook)?;
            continue;
        }

        match super::next_line(file, lines, pos, "Hecksagon")? {
            None => return Ok(()),
            Some(gated) => match gated.row.word {
                // A PORT DECLARED BARE AT THE ROOT — belongs to the CHAPTER
                // as a whole (`HecksagonBuilder#port`), not one aggregate.
                // `IR::Bluebook#to_h` carries no `ports:` key at all (only
                // an AGGREGATE's own ports do, via `IR::Aggregate#to_h` —
                // confirmed by reading `bluebook.rb` directly: `@ports`
                // exists on the Ruby object but `to_h` never spells it).
                // Parsed and validated for real, then discarded — not
                // exercised by pizzas.hecksagon (its one port is
                // aggregate-scoped), kept correct anyway.
                "port" => {
                    let name = super::positional_text(file, gated.line.number, "port", &gated.args, 1)?;
                    let _ = domain_port::parse_body(file, lines, pos, &name, None)?;
                }
                // `uses_framework "Governance"`/`subscribe "..."` —
                // ACCEPTED AND IGNORED, per the plan's own finding #5:
                // `.hecksagon` contributes exactly two things to `ir.json`
                // (`port ... do ... end` and `uses_framework` ITSELF, but
                // only in the sense of "which OTHER chapters get
                // generated" — `IR::Bluebook#to_h` carries no
                // `framework_members`/`uses_framework` key at all,
                // confirmed by reading `bluebook.rb` directly). Gated for
                // real (word/body/argument all already ran above), then
                // dropped — the SAME "shape-matched, contents dropped"
                // treatment `apply_aggregate_qualified` already gives
                // `persisted_by`/`projected_by`. Confirmed real:
                // banking.hecksagon's own `uses_framework "Governance"`/
                // `"Identity"`.
                "uses_framework" | "subscribe" => {}
                _ => return Err(super::not_built_yet("Hecksagon", gated.row, file, gated.line.number, &gated.call.word)),
            },
        }
    }
}

/// `<Domain>::<Aggregate>.<verb>` — `verb == "port"` is `BindingProxy`'s
/// own REAL method (aggregate-scoped `IR::DomainPort`, attached onto the
/// aggregate this receiver names); anything else is `BindingProxy#
/// method_missing`'s generic adapter-bind (`persisted_by`, `projected_by`,
/// any other verb) — shape-matched and dropped, per this module's own
/// header.
fn apply_aggregate_qualified(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    line_number: usize,
    receiver: &str,
    rest: &str,
    bluebook: &mut ir::Bluebook,
) -> ParseResult<()> {
    let synthetic = SourceLine { number: line_number, text: rest };
    let shape = lex::classify(file, &synthetic)?;
    let call = match shape {
        LineShape::Call(call) => call,
        LineShape::End => return Err(Diagnostic::new(file, line_number, "unexpected 'end' right after an aggregate-qualified receiver")),
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

    let aggregate = bluebook.aggregates.iter_mut().find(|a| a.name == aggregate_name).ok_or_else(|| {
        Diagnostic::new(file, line_number, format!("{receiver} declares no such aggregate — a port needs one to belong to"))
    })?;
    aggregate.ports.push(built);
    Ok(())
}

/// Skips a dropped adapter-bind's own `do ... end` body (never actually
/// exercised by pizzas.hecksagon — every bind there is a bare, blockless
/// call — kept for the same reason `HecksagonBuilder#method_missing`
/// itself still calls `block&.call`: the open vocabulary's shape covers
/// this too). Content is never interpreted, only depth-tracked via the
/// SAME shape gate every other line goes through, so a malformed line
/// inside a dropped block still refuses rather than being silently
/// swallowed.
fn skip_dropped_body(file: &str, lines: &[SourceLine], pos: &mut usize) -> ParseResult<()> {
    let mut depth = 1;
    while depth > 0 {
        let line = *lines.get(*pos).ok_or_else(|| {
            let last = lines.last().map(|l| l.number).unwrap_or(0);
            Diagnostic::new(file, last, "unexpected end of file while skipping a dropped adapter-bind body")
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
