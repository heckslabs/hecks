//! The `Policy` construct (`lib/hecks/bluebook/ir/policy.rb`,
//! `Hecks::Bluebook::DSL::PolicyBuilder`) — `on`/`trigger` filling
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

// STAGE 4: `across` (a cross-domain policy's `target_domain`) —
// confirmed real: banking.bluebook's own `NotifyOnClosure`/
// `ReviewOnFreeze`/`ReviewOnBoxSurrender`/`FlagKeyReturn`. Also newly
// real: a policy declared INSIDE an `aggregate` (Account's own
// `ReviewOnFreeze`) — `parse::aggregate` calls this SAME `parse_body`
// and hoists the result onto the chapter itself, mirroring
// `AggregateBuilder#policy`'s own hoist.

/// Parses a `policy "Name" do ... end` body, given the header's already-
/// read `name`.
pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
) -> ParseResult<ir::Policy> {
    let mut policy = ir::Policy {
        name: name.to_string(),
        ..Default::default()
    };

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Policy")? else {
            return Ok(policy);
        };

        match gated.row.word {
            "on" => {
                policy.on_event = Some(super::positional_text(
                    file,
                    gated.line.number,
                    "on",
                    &gated.args,
                    1,
                )?)
            }
            "trigger" => {
                policy.trigger_command = Some(super::positional_command_ref(
                    file,
                    gated.line.number,
                    "trigger",
                    &gated.args,
                    1,
                )?);
                // STAGE 4: `trigger`'s own `with:` — the projection
                // between an event's shape and its trigger's. Read by
                // the SAME parser `dispatch`'s own `with:` uses; the two
                // are the same word in two places, and reading them two
                // ways is how they would drift.
                policy.with_spec = super::process_manager::parse_with_pairs_opt(&gated.args);
            }
            "across" => {
                policy.target_domain = Some(super::positional_text(
                    file,
                    gated.line.number,
                    "across",
                    &gated.args,
                    1,
                )?)
            }
            // STAGE 4: `for_each` (fan-out — one `trigger` per row a
            // declared query answers) — newly real: banking.bluebook's
            // own `FreezeAccountsOnSuspension`, which is what a
            // suspension needs to reach every account a customer holds.
            // `ir::Policy` and `emit::policy_json` already carried the
            // field and the `for_each` JSON key; only this arm was
            // missing, so nothing about the wire format changes.
            //
            // `where` stays unbuilt: it is a BLOCK, not a positional
            // text, and no corpus member declares one.
            "for_each" => {
                policy.for_each_query = Some(super::positional_text(
                    file,
                    gated.line.number,
                    "for_each",
                    &gated.args,
                    1,
                )?)
            }
            _ => {
                return Err(super::not_built_yet(
                    "Policy",
                    gated.row,
                    file,
                    gated.line.number,
                    &gated.call.word,
                ))
            }
        }
    }
}
