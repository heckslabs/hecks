//! The `Aggregate` construct (`lib/hecksagain/bluebook/ir/aggregate.rb`,
//! built by `Hecksagain::Bluebook::DSL::AggregateBuilder`). STAGE 3 adds
//! the MULTI-PATH `identified_by do ... end`/`identified_by { ... }`
//! source form (`build/identity.rs`'s own header explains why it needs no
//! `build/*.rs` derivation at all — its body IS the identity, captured
//! raw) and inline `one_of(...)` closed-set synthesis
//! (`build/closed_sets.rs`) folded into this aggregate's own
//! `value_objects`. Still open: the bare-FIELD form (`identified_by
//! :field`, not exercised by any real corpus member yet),
//! `reference_to`/`has_many`/`has_one`/`belongs_to` attribute-minting,
//! and folding a nested `lifecycle` block — `entity`/`reference_to` stay
//! `not_built_yet`.

use super::{command, lifecycle, query, value_object};
use crate::build::{identity, references};
use crate::canonical;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{Opener, SourceLine};

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Aggregate.{word}"))
}

/// The `identified_by` forms this parser actually resolves/refuses — see
/// `build/identity.rs`'s own header for why the TYPE form is a
/// DERIVATION (`build/identity.rs::resolve_identity_type`) while `Paths`
/// (the SOURCE-shaped block form, either spelling) is not: its body
/// already IS the identity, captured raw and canonicalized, never
/// resolved against already-declared attributes. The FIELD form
/// (`identified_by :field`) is still left `not_yet_implemented` — no real
/// corpus member exercises it yet.
enum PendingIdentity {
    Type { line: usize, target: String, as_field: Option<String>, insert_at: usize },
    Paths(Vec<String>),
}

/// Parses an `aggregate "Name" do ... end` body. `identified_by`'s TYPE
/// form is DEFERRED to the end (mirroring `AggregateBuilder#build`'s own
/// `resolve_pending_identity!`, called only once every `value_object`
/// inside this same body has been declared) — pizzas.bluebook's own
/// `PizzaName` value object is declared AFTER `identified_by PizzaName,
/// as: :name`, so resolving eagerly would find no value objects yet. The
/// SOURCE (block) form needs no such deferral — its paths are already
/// literal text, not a lookup — so it's resolved immediately, matching
/// `AggregateBuilder#identified_by`'s own `@identity_paths = paths`
/// direct assignment.
///
/// Inline `one_of(...)` closed sets (`attribute :tone, one_of(...)`) are
/// collected SEPARATELY from `value_object "Name" do ... end` blocks and
/// appended AFTER them — mirroring `AggregateBuilder#build`'s own
/// `@value_objects + closed_sets` ORDER exactly (confirmed against
/// console_settings.bluebook's own `StateStyle`: its three explicit
/// `value_object`s come first in `ir.json`, `Tone` — synthesized from
/// `attribute :tone, one_of(...)`, written BEFORE two of those three in
/// the source — comes last regardless).
pub fn parse_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str) -> ParseResult<ir::Aggregate> {
    let mut aggregate = ir::Aggregate { name: name.to_string(), ..Default::default() };
    let mut pending_identity: Option<PendingIdentity> = None;
    let mut closed_sets: Vec<ir::ValueObject> = Vec::new();

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Aggregate")? else {
            break;
        };
        let line = gated.line.number;

        match gated.row.word {
            "description" => aggregate.description = Some(super::positional_text(file, line, "description", &gated.args, 1)?),
            "attribute" => {
                let (attr, vo) = super::build_attribute(file, line, "attribute", &gated.args)?;
                aggregate.attributes.push(attr);
                if let Some(vo) = vo {
                    closed_sets.push(vo);
                }
            }
            "identified_by" => {
                pending_identity = Some(parse_identified_by(file, lines, pos, line, &gated.args, &gated.call.opener, aggregate.attributes.len())?)
            }
            // `AggregateBuilder#reference_to(type, as: nil)` — mints a
            // reference attribute directly on the aggregate, the SAME
            // shape `references::reference_attribute` already builds for
            // a command's own `reference_to` (`command.rs`'s
            // `apply_reference_to`). Confirmed real: identity.bluebook's
            // own `ExternalIdentifier` (`reference_to Identity`, no
            // `as:` — mints `identity_id`). Unlike the command form,
            // there's no "self-reference means acts_on, not an
            // attribute" distinction here at all — an aggregate's own
            // `reference_to` is ALWAYS an attribute mint; `has_many`/
            // `has_one`/`belongs_to` share the same field but are not
            // exercised by any of the three framework bluebooks, so stay
            // unbuilt.
            "reference_to" => {
                let target_raw = super::positional_constant(file, line, "reference_to", &gated.args, 1)?;
                let target = crate::build::naming::demodulise(target_raw);
                let as_name = super::named_symbol(&gated.args, "as");
                aggregate.attributes.push(references::reference_attribute(&target, as_name.as_deref(), false));
            }
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

    // EXPLICIT value objects first, closed sets appended after — see this
    // function's own header. Done BEFORE resolving a pending TYPE-form
    // identity, matching Ruby's own `resolve_identity_type!(..., @value_objects
    // + closed_sets, ...)` call — the target value object a TYPE-form
    // `identified_by` names could, in principle, itself be an inline
    // closed set (not exercised by any real corpus member today, kept
    // correct anyway).
    aggregate.value_objects.extend(closed_sets);

    if let Some(pending) = pending_identity {
        match pending {
            PendingIdentity::Type { line, target, as_field, insert_at } => {
                aggregate.identified_by =
                    identity::resolve_identity_type(file, line, name, &target, as_field.as_deref(), insert_at, &aggregate.value_objects, &mut aggregate.attributes)?;
            }
            PendingIdentity::Paths(paths) => aggregate.identified_by = paths,
        }
    }

    Ok(aggregate)
}

/// `AggregateBuilder#identified_by` — the THREE forms Ruby's own single
/// method distinguishes: a bareword starting uppercase is a value object
/// (the TYPE form, `identified_by PizzaName, as: :name`, `Opener::None`);
/// starting lowercase (a Symbol) is the FIELD form (`identified_by
/// :field`, `Opener::None`, still not exercised by any real corpus member
/// — refused with an honest not-yet-implemented diagnostic); a BLOCK —
/// spelled either `identified_by { ... }` (`Opener::BraceBlock`) or
/// `identified_by do ... end` (`Opener::DoBlock`, governance.bluebook's/
/// console_settings.bluebook's own multi-path identity, STAGE 3) — is the
/// SOURCE form, captured raw and canonicalized (never resolved against
/// declared attributes), one path per whitespace-separated token in the
/// canonical text, mirroring `Ports::Extraction.canonical(path).to_s
/// .split(" ").reject(&:empty?)` exactly.
fn parse_identified_by(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    line: usize,
    args: &super::ArgumentGateResult,
    opener: &Opener,
    insert_at: usize,
) -> ParseResult<PendingIdentity> {
    match opener {
        Opener::None => {
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
        Opener::DoBlock { .. } | Opener::BraceBlock { .. } => {
            let raw = super::source_body_text(file, lines, pos, opener)?;
            paths_from_source(file, line, &raw)
        }
    }
}

/// `identified_by`'s SOURCE-shaped body (either spelling) -> its own
/// identity paths, canonicalized and whitespace-split — see
/// `parse_identified_by`'s own header.
fn paths_from_source(file: &str, line: usize, raw: &str) -> ParseResult<PendingIdentity> {
    let canonical = canonical::apply(raw);
    let paths: Vec<String> = canonical.split(' ').filter(|s| !s.is_empty()).map(str::to_string).collect();
    if paths.is_empty() {
        return Err(Diagnostic::new(file, line, "'identified_by' names no field"));
    }
    Ok(PendingIdentity::Paths(paths))
}
