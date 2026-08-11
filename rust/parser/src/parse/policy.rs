//! The `Policy` construct (`lib/hecksagain/bluebook/ir/policy.rb`,
//! `Hecksagain::Bluebook::DSL::PolicyBuilder`) — `on`/`trigger` filling
//! `on_event`/`trigger_command`. Confirmed real: pizzas.bluebook's own
//! `OnPizzaPaymentReceived`, declared directly on the CHAPTER (never
//! inside an `aggregate` — a policy written on an aggregate is HOISTED
//! onto the chapter by `AggregateBuilder#policy`, `hoisted onto the
//! chapter by the builder` per `IR::Policy`'s own `aggregate` accessor —
//! not exercised here, since nothing in pizzas.bluebook writes one that
//! way). `across` (a cross-domain policy's `target_domain`) is not
//! exercised either — left to fall through to `not_built_yet` if ever
//! encountered.

use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Policy.{word}"))
}

/// Parses a `policy "Name" do ... end` body, given the header's already-
/// read `name`.
pub fn parse_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str) -> ParseResult<ir::Policy> {
    let mut policy = ir::Policy { name: name.to_string(), ..Default::default() };

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Policy")? else {
            return Ok(policy);
        };

        match gated.row.word {
            "on" => policy.on_event = Some(super::positional_text(file, gated.line.number, "on", &gated.args, 1)?),
            "trigger" => policy.trigger_command = Some(super::positional_text(file, gated.line.number, "trigger", &gated.args, 1)?),
            _ => return Err(super::not_built_yet("Policy", gated.row, file, gated.line.number, &gated.call.word)),
        }
    }
}
