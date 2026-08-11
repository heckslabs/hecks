//! The `DomainPort`/`PortOperation` constructs
//! (`lib/hecksagain/bluebook/ir/domain_port.rb`) — shared here the same
//! way `spec/syntax_conformance_spec.rb`'s own `BUILDER` table pairs
//! `PortOperationBuilder` with `DomainPortBuilder`. The PRIMARY/DRIVING
//! half of hexagonal architecture: an operation carries no `given`/
//! `ensures`/`then_set` (a port is the anti-corruption boundary, not a
//! second place business rules live), but it does need `identity_attribute`
//! resolution — a reference attribute targeting the owning aggregate,
//! required so a dispatched operation always names a record.

use crate::diag::Diagnostic;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("DomainPort.{word}"))
}
