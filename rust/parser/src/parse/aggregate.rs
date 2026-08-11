//! The `Aggregate` construct (`lib/hecksagain/bluebook/ir/aggregate.rb`,
//! built by `Hecksagain::Bluebook::DSL::AggregateBuilder`). Stage 2+ work:
//! `identified_by`'s three forms (block/bare-field/bare-type — see
//! `attribute_collector.rb`'s `resolve_identity_field!`/
//! `resolve_identity_type!`), `reference_to`/`has_many`/`has_one`/
//! `belongs_to` attribute-minting, `value_object`/`one_of` closed-set
//! synthesis, and folding a nested `lifecycle` block onto this record —
//! each mirrored in `build/identity.rs`, `build/references.rs`,
//! `build/closed_sets.rs` respectively, once those stop being stubs.
//!
//! Stage 1: reached only when `parse::walk_body` has already gated (for
//! real) the `aggregate "Name" do` header AND every line of its own body,
//! recursing through nested `do` blocks the identical way — this stub is
//! the honest admission that none of it is built into `ir::Aggregate` yet.

use super::{command, lifecycle, query, value_object};
use crate::build::identity;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Aggregate.{word}"))
}

/// The two `identified_by` forms this parser actually resolves/refuses —
/// see `build/identity.rs`'s own header for why the TYPE form is the one
/// pizzas.bluebook exercises (`identified_by PizzaName, as: :name`) and
/// the FIELD form (`identified_by :field`) is left `not_yet_implemented`.
enum PendingIdentity {
    Type { line: usize, target: String, as_field: Option<String>, insert_at: usize },
}

/// Parses an `aggregate "Name" do ... end` body. `identified_by` is
/// DEFERRED to the end (mirroring `AggregateBuilder#build`'s own
/// `resolve_pending_identity!`, called only once every `value_object`
/// inside this same body has been declared) — pizzas.bluebook's own
/// `PizzaName` value object is declared AFTER `identified_by PizzaName,
/// as: :name`, so resolving eagerly would find no value objects yet.
pub fn parse_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str) -> ParseResult<ir::Aggregate> {
    let mut aggregate = ir::Aggregate { name: name.to_string(), ..Default::default() };
    let mut pending_identity: Option<PendingIdentity> = None;

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Aggregate")? else {
            break;
        };
        let line = gated.line.number;

        match gated.row.word {
            "description" => aggregate.description = Some(super::positional_text(file, line, "description", &gated.args, 1)?),
            "attribute" => aggregate.attributes.push(super::build_attribute(file, line, "attribute", &gated.args)?),
            "identified_by" => pending_identity = Some(parse_identified_by(file, line, &gated.args, gated.row.body, aggregate.attributes.len())?),
            "value_object" => {
                let vo_name = super::positional_text(file, line, "value_object", &gated.args, 1)?;
                aggregate.value_objects.push(value_object::parse_body(file, lines, pos, &vo_name)?);
            }
            "lifecycle" => {
                let field = super::positional_symbol(file, line, "lifecycle", &gated.args, 1)?;
                let default = super::named_text(&gated.args, "default")
                    .ok_or_else(|| Diagnostic::new(file, line, "'lifecycle' requires a default:"))?;
                aggregate.lifecycle = Some(lifecycle::parse_body(file, lines, pos, &field, &default)?);
            }
            "query" => {
                let q_name = super::positional_text(file, line, "query", &gated.args, 1)?;
                aggregate.queries.push(query::parse_body(file, lines, pos, &q_name)?);
            }
            "command" => {
                let c_name = super::positional_text(file, line, "command", &gated.args, 1)?;
                aggregate.commands.push(command::parse_body(file, lines, pos, &c_name, name)?);
            }
            _ => return Err(super::not_built_yet("Aggregate", gated.row, file, line, &gated.call.word)),
        }
    }

    if let Some(pending) = pending_identity {
        match pending {
            PendingIdentity::Type { line, target, as_field, insert_at } => {
                aggregate.identified_by =
                    identity::resolve_identity_type(file, line, name, &target, as_field.as_deref(), insert_at, &aggregate.value_objects, &mut aggregate.attributes)?;
            }
        }
    }

    Ok(aggregate)
}

/// `AggregateBuilder#identified_by` — distinguishes its TWO blockless
/// forms the same way Ruby does: a bareword starting uppercase is a value
/// object (the TYPE form, `identified_by PizzaName, as: :name`); starting
/// lowercase (a Symbol) is the FIELD form (`identified_by :field`, not
/// exercised by pizzas.bluebook — refused here with an honest
/// not-yet-implemented diagnostic rather than guessed at). The SOURCE
/// (block) form — `identified_by { name.value }` — is a THIRD form this
/// same word admits, not reached from this call site at all (its own
/// `KeywordRow.body == "source"`, a different `Opener`).
fn parse_identified_by(file: &str, line: usize, args: &super::ArgumentGateResult, body: &str, insert_at: usize) -> ParseResult<PendingIdentity> {
    if body != "none" {
        return Err(Diagnostic::not_yet_implemented(file, line, "Aggregate.identified_by (block form)"));
    }

    let text = super::positional_constant(file, line, "identified_by", args, 1)?;
    match super::classify_lexical_kind(text) {
        "constant" => {
            let as_field = super::named_symbol(args, "as");
            Ok(PendingIdentity::Type { line, target: text.to_string(), as_field, insert_at })
        }
        "symbol" => Err(Diagnostic::not_yet_implemented(file, line, "Aggregate.identified_by (bare-field form)")),
        other => Err(Diagnostic::new(file, line, format!("'identified_by's positional argument reads as {other}, neither a value object nor a field"))),
    }
}
