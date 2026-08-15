//! The `Entity` construct (`lib/hecksagain/bluebook/ir/entity.rb`, built
//! by `Hecksagain::Bluebook::DSL::EntityBuilder`) — a piece of an
//! aggregate with an identity of its own. STAGE 4: `EntityBuilder`
//! `include AttributeCollector`, the SAME module `AggregateBuilder` does,
//! and its own `identified_by` is (per its own comment) "the aggregate's
//! method line for line" — so this mirrors `parse::aggregate`'s own
//! `identified_by` handling exactly, via the SHARED `parse::
//! parse_identified_by`/`PendingIdentity` (`parse::mod`'s own header) —
//! not a second, parallel copy. A piece says less than a head
//! (syntax.bluebook's own comment): no `value_object`, no `policy`, no
//! nested `entity`, no `reference_to` — the words an entity actually
//! declares are `description`/`identified_by`/`attribute`/`command`/
//! `query`/`lifecycle`, confirmed real by banking.bluebook's own
//! `LedgerEntry`/`Withdrawal`/`Visit`/`KeyIssuance` (composite AND
//! single-path identities, both TYPE and block/Paths forms).

use super::{command, lifecycle, query};
use crate::build::identity;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Entity.{word}"))
}

/// Parses an `entity "Name" do ... end` body. `owner_value_objects` is
/// the OWNING aggregate's own `@value_objects + closed_sets` AT THE POINT
/// `entity` was called (`AggregateBuilder#entity`'s own comment) — an
/// entity holds none of its own, so a TYPE-form `identified_by` here
/// (`identified_by LedgerSequence, as: :sequence`) resolves against the
/// aggregate's, exactly like `EntityBuilder#resolve_pending_identity!`
/// does with the `owner_value_objects:` it was constructed with.
pub fn parse_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str, owner_value_objects: &[ir::ValueObject]) -> ParseResult<ir::Entity> {
    let mut entity = ir::Entity { name: name.to_string(), ..Default::default() };
    let mut pending_identity: Option<super::PendingIdentity> = None;

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Entity")? else {
            break;
        };
        let line = gated.line.number;

        match gated.row.word {
            "description" => entity.description = Some(super::positional_text(file, line, "description", &gated.args, 1)?),
            "attribute" => entity.attributes.push(super::build_attribute(file, line, "attribute", &gated.args)?.0),
            "identified_by" => {
                pending_identity =
                    Some(super::parse_identified_by(file, lines, pos, line, &gated.args, &gated.call.opener, entity.attributes.len())?)
            }
            "lifecycle" => {
                let field = super::positional_symbol(file, line, "lifecycle", &gated.args, 1)?;
                let default = super::named_text(&gated.args, "default")
                    .ok_or_else(|| Diagnostic::new(file, line, "'lifecycle' requires a default:"))?;
                entity.lifecycle = Some(lifecycle::parse_body(file, lines, pos, &field, &default)?);
            }
            "command" => {
                let c_name = super::positional_text(file, line, "command", &gated.args, 1)?;
                let from = command::parse_from(file, line, &gated.args)?;
                // AN ENTITY OFFERS NO PRECONDITIONS OF ITS OWN
                // (`EntityBuilder#command` never forwards `named_givens:`
                // — see `command::try_reference_named_given`'s own
                // header) — a bare `given(...)` here always fails
                // resolution, matching Ruby's own refusal.
                entity.commands.push(command::parse_body(file, lines, pos, &c_name, name, from, &[])?);
            }
            "query" => {
                let q_name = super::positional_text(file, line, "query", &gated.args, 1)?;
                entity.queries.push(query::parse_body(file, lines, pos, &q_name)?);
            }
            _ => return Err(super::not_built_yet("Entity", gated.row, file, line, &gated.call.word)),
        }
    }

    if let Some(pending) = pending_identity {
        match pending {
            super::PendingIdentity::Type { line, target, as_field, insert_at } => {
                entity.identified_by =
                    identity::resolve_identity_type(file, line, name, &target, as_field.as_deref(), insert_at, owner_value_objects, &mut entity.attributes)?;
            }
            super::PendingIdentity::Fields { line, names } => {
                entity.identified_by = names
                    .iter()
                    .map(|field| identity::resolve_identity_field(file, line, name, field, owner_value_objects, &entity.attributes))
                    .collect::<crate::diag::ParseResult<Vec<String>>>()?;
            }
            super::PendingIdentity::Paths(paths) => entity.identified_by = paths,
        }
    }

    Ok(entity)
}
