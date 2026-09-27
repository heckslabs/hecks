//! The `Policy` construct: `on`/`trigger` fill `on_event`/`trigger_command`, `across` names the
//! target domain.

use crate::canonical;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Policy.{word}"))
}

/// Parses a `policy "Name" do ... end` body, given the header's already-read `name`.
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
            // `::` in a qualified constant rewrites to `.`, matching Ruby's `Naming.event_ref`.
            "on" => {
                policy.on_event = Some(super::positional_command_ref(
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
                // Shares `dispatch`'s `with:` parser so the two cannot drift.
                policy.with_spec = super::process_manager::parse_with_pairs_opt(&gated.args);
            }
            "across" => {
                policy.target_domain = Some(super::positional_text(
                    file,
                    gated.line.number,
                    "across",
                    &gated.args,
                    1,
                )?);
                policy.expect_undelivered = super::named_flag(&gated.args, "expect_undelivered");
            }
            // Same extraction as `parse::command`'s `given`/`ensures`; `where` has no description.
            "where" => {
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                policy.where_clause = Some(canonical::apply(&raw));
            }
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
