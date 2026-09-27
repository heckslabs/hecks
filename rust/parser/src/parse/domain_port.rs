//! The `DomainPort`/`PortOperation` constructs: the driving half of a hexagonal boundary.
//! An operation carries no `given`/`ensures`/`sets`; its receiver comes from `to:`.

use crate::build::naming;
use crate::build::references;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("DomainPort.{word}"))
}

/// Parses a `port "Name" do ... end` body: `operation` entries only.
/// Any other word, including `verb`, falls through to `not_built_yet`.
pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
    _owner: Option<&str>,
) -> ParseResult<ir::DomainPort> {
    let mut port = ir::DomainPort {
        name: name.to_string(),
        operations: Vec::new(),
    };

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "DomainPort")? else {
            return Ok(port);
        };
        let line = gated.line.number;

        match gated.row.word {
            "operation" => {
                let op_name = super::positional_text(file, line, "operation", &gated.args, 1)?;
                let to = super::named_constant(&gated.args, "to").map(naming::demodulise);
                port.operations
                    .push(parse_operation_body(file, lines, pos, &op_name, to)?);
            }
            _ => {
                return Err(super::not_built_yet(
                    "DomainPort",
                    gated.row,
                    file,
                    line,
                    &gated.call.word,
                ))
            }
        }
    }
}

/// An operation's `reference_to` always mints an attribute, never a self-reference.
fn parse_operation_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
    to: Option<String>,
) -> ParseResult<ir::PortOperation> {
    let mut operation = ir::PortOperation {
        name: name.to_string(),
        attributes: Vec::new(),
        emits: Vec::new(),
        to,
    };

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "PortOperation")? else {
            validate_operation(file, pos_line(lines, pos), &operation)?;
            return Ok(operation);
        };
        let line = gated.line.number;

        match gated.row.word {
            // A synthesized inline `one_of(...)` closed set is dropped, as
            // `DomainPortBuilder#build` does.
            "attribute" => operation
                .attributes
                .push(super::build_attribute(file, line, "attribute", &gated.args)?.0),
            "emits" => {
                operation
                    .emits
                    .push(super::positional_text(file, line, "emits", &gated.args, 1)?)
            }
            "reference_to" => {
                let target_raw =
                    super::positional_constant(file, line, "reference_to", &gated.args, 1)?;
                let target = naming::demodulise(target_raw);
                let as_name = super::named_symbol(&gated.args, "as");
                operation.attributes.push(references::reference_attribute(
                    &target,
                    as_name.as_deref(),
                    false,
                ));
            }
            _ => {
                return Err(super::not_built_yet(
                    "PortOperation",
                    gated.row,
                    file,
                    line,
                    &gated.call.word,
                ))
            }
        }
    }
}

/// The last consumed line, for diagnostics; 0 when none.
fn pos_line(lines: &[SourceLine], pos: &usize) -> usize {
    lines
        .get(pos.saturating_sub(1))
        .map(|l| l.number)
        .unwrap_or(0)
}

/// An inbound operation must emit something. The receiver comes from the routing envelope,
/// so it is not validated as an attribute.
fn validate_operation(file: &str, line: usize, operation: &ir::PortOperation) -> ParseResult<()> {
    if operation.emits.is_empty() {
        return Err(Diagnostic::new(file, line, format!("'{}' declares no emits — an operation with nothing to say afterward is a call into nothing", operation.name)));
    }

    Ok(())
}
