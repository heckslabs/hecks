//! The `DomainPort`/`PortOperation` constructs
//! (`lib/hecksagain/bluebook/ir/domain_port.rb`) — shared here the same
//! way `spec/syntax_conformance_spec.rb`'s own `BUILDER` table pairs
//! `PortOperationBuilder` with `DomainPortBuilder`. The PRIMARY/DRIVING
//! half of hexagonal architecture: an operation carries no `given`/
//! `ensures`/`sets` (a port is the anti-corruption boundary, not a
//! second place business rules live), but it does need `identity_attribute`
//! resolution — a reference attribute targeting the owning aggregate,
//! required so a dispatched operation always names a record.

use crate::build::naming;
use crate::build::references;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("DomainPort.{word}"))
}

/// Parses a `port "Name" do ... end` body — `operation "Name" do ... end`
/// entries only; `verb` (the OTHER shape a port can take, `IR::Port`, the
/// driven/outbound half — see `DomainPortBuilder#verb`'s own comment) is
/// not exercised by pizzas.bluebook's own port and falls through to
/// `not_built_yet` if ever written here.
pub fn parse_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str, owner: Option<&str>) -> ParseResult<ir::DomainPort> {
    let mut port = ir::DomainPort { name: name.to_string(), operations: Vec::new() };

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "DomainPort")? else {
            return Ok(port);
        };
        let line = gated.line.number;

        match gated.row.word {
            "operation" => {
                let op_name = super::positional_text(file, line, "operation", &gated.args, 1)?;
                port.operations.push(parse_operation_body(file, lines, pos, &op_name, owner)?);
            }
            _ => return Err(super::not_built_yet("DomainPort", gated.row, file, line, &gated.call.word)),
        }
    }
}

/// `PortOperationBuilder` — an operation's own `reference_to` ALWAYS
/// mints an attribute (never the self-reference a command's own
/// `reference_to` may spell — see `PortOperationBuilder#reference_to`'s
/// own comment: "there is no `creates?`/`acts_on` distinction to protect
/// here").
fn parse_operation_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str, owner: Option<&str>) -> ParseResult<ir::PortOperation> {
    let mut operation = ir::PortOperation { name: name.to_string(), attributes: Vec::new(), emits: Vec::new() };

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "PortOperation")? else {
            validate_operation(file, pos_line(lines, pos), &operation, owner)?;
            return Ok(operation);
        };
        let line = gated.line.number;

        match gated.row.word {
            // A synthesized inline `one_of(...)` closed set is discarded
            // here on purpose — see `build/closed_sets.rs`'s own header;
            // `DomainPortBuilder#build` never reads `closed_sets` either.
            "attribute" => operation.attributes.push(super::build_attribute(file, line, "attribute", &gated.args)?.0),
            "emits" => operation.emits.push(super::positional_text(file, line, "emits", &gated.args, 1)?),
            "reference_to" => {
                let target_raw = super::positional_constant(file, line, "reference_to", &gated.args, 1)?;
                let target = naming::demodulise(target_raw);
                let as_name = super::named_symbol(&gated.args, "as");
                operation.attributes.push(references::reference_attribute(&target, as_name.as_deref(), false));
            }
            _ => return Err(super::not_built_yet("PortOperation", gated.row, file, line, &gated.call.word)),
        }
    }
}

/// The last line consumed, used only to attach a real line number to the
/// "no emits"/"no owner reference" checks below — falls back to line 0
/// (never surfaced to a user: both checks below only fire on a genuinely
/// malformed operation, and pizzas.bluebook's own `Receive` operation
/// satisfies both).
fn pos_line(lines: &[SourceLine], pos: &usize) -> usize {
    lines.get(pos.saturating_sub(1)).map(|l| l.number).unwrap_or(0)
}

/// `PortOperationBuilder#build`'s own two checks: an operation must emit
/// something, and — only when it belongs to ONE aggregate (`owner`
/// given) — must carry a `reference_to` naming that aggregate, so a
/// dispatched operation always says which record it's about.
fn validate_operation(file: &str, line: usize, operation: &ir::PortOperation, owner: Option<&str>) -> ParseResult<()> {
    if operation.emits.is_empty() {
        return Err(Diagnostic::new(file, line, format!("'{}' declares no emits — an operation with nothing to say afterward is a call into nothing", operation.name)));
    }

    if let Some(owner) = owner {
        let names_owner = operation.attributes.iter().any(|a| a.reference_target() == Some(owner));
        if !names_owner {
            return Err(Diagnostic::new(
                file,
                line,
                format!("'{}' names no reference_to {owner} — an operation needs one to say which {owner} its emitted event belongs to", operation.name),
            ));
        }
    }

    Ok(())
}
