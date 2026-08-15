//! The `Aggregate` construct (`lib/hecksagain/bluebook/ir/aggregate.rb`,
//! built by `Hecksagain::Bluebook::DSL::AggregateBuilder`). STAGE 3 adds
//! the MULTI-PATH `identified_by do ... end`/`identified_by { ... }`
//! source form (`build/identity.rs`'s own header explains why it needs no
//! `build/*.rs` derivation at all — its body IS the identity, captured
//! raw) and inline `one_of(...)` closed-set synthesis
//! (`build/closed_sets.rs`) folded into this aggregate's own
//! `value_objects`. STAGE 4 adds `provenance` (a raw captured Hash,
//! `ir::Literal` — see `ir.rs`'s own comment), a nested `policy` (hoisted
//! onto the CHAPTER by Ruby's own `AggregateBuilder#policy`, so this
//! module returns it SEPARATELY rather than folding it into
//! `ir::Aggregate` — `parse::chapter`'s own header explains the bubbling
//! order), `belongs_to`/`has_one` (`has_many` stays unbuilt — no real
//! corpus member exercises it yet), and a real `entity` (`parse::entity`,
//! previously fully stubbed). Still open: the bare-FIELD `identified_by`
//! form (`identified_by :field`, not exercised by any real corpus member
//! yet).

use super::{command, entity, lifecycle, policy, query, value_object};
use crate::build::{identity, naming, references};
use crate::canonical;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;
use crate::ruby_value;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Aggregate.{word}"))
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
/// Returns the built aggregate ALONGSIDE any `policy`s declared directly
/// inside it — `AggregateBuilder#policy` HOISTS a nested policy onto the
/// CHAPTER (`IR::Policy#aggregate`'s own comment: "a policy written
/// inside an aggregate is HOISTED onto the chapter by the builder"), and
/// `IR::Aggregate#to_h` never spells `policies` at all — confirmed by
/// reading `aggregate.rb` directly. So this can't fold a nested policy
/// into `ir::Aggregate` the way it does `commands`/`queries`/etc; the
/// caller (`parse::chapter`) bubbles the returned `Vec<ir::Policy>` onto
/// `ir::Bluebook.policies` itself, in the exact order
/// `BluebookBuilder#build`'s own `@aggregates.flat_map(&:policies) +
/// @policies` produces (every aggregate's own policies, in aggregate
/// order, THEN every chapter-level one).
pub fn parse_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str) -> ParseResult<(ir::Aggregate, Vec<ir::Policy>)> {
    let mut aggregate = ir::Aggregate { name: name.to_string(), ..Default::default() };
    let mut pending_identity: Option<super::PendingIdentity> = None;
    let mut closed_sets: Vec<ir::ValueObject> = Vec::new();
    let mut policies: Vec<ir::Policy> = Vec::new();

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Aggregate")? else {
            break;
        };
        let line = gated.line.number;

        match gated.row.word {
            "description" => aggregate.description = Some(super::positional_text(file, line, "description", &gated.args, 1)?),
            // `AggregateBuilder#provenance(from:)` — ORIGIN, not identity:
            // captured raw, the same "whatever the author wrote" shape
            // `attribute ..., default: { ... }` already uses for a
            // literal Hash. `IR::Aggregate#to_h`'s own `provenance:
            // @provenance` embeds the raw Ruby Hash straight into
            // `JSON.generate`, never through `Literal.render` — see
            // `ir::Literal`'s own header and `ir.rs::Aggregate.provenance`'s
            // comment. Confirmed real: banking.bluebook's own `Account`.
            "provenance" => {
                let raw = super::named_raw(&gated.args, "from")
                    .ok_or_else(|| Diagnostic::new(file, line, "'provenance' requires a from:"))?;
                aggregate.provenance = Some(ruby_value::read(raw.trim()));
            }
            "attribute" => {
                let (attr, vo) = super::build_attribute(file, line, "attribute", &gated.args)?;
                aggregate.attributes.push(attr);
                if let Some(vo) = vo {
                    closed_sets.push(vo);
                }
            }
            "identified_by" => {
                pending_identity =
                    Some(super::parse_identified_by(file, lines, pos, line, &gated.args, &gated.call.opener, aggregate.attributes.len())?)
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
            // `reference_to` is ALWAYS an attribute mint.
            "reference_to" => {
                let target_raw = super::positional_constant(file, line, "reference_to", &gated.args, 1)?;
                let target = naming::demodulise(target_raw);
                let as_name = super::named_symbol(&gated.args, "as");
                aggregate.attributes.push(references::reference_attribute(&target, as_name.as_deref(), false));
            }
            // `has_one`/`belongs_to` — sugar over `reference_to` minting
            // NO `_id` suffix (`AggregateBuilder#has_one`: `reference_to(type,
            // as: as || Naming.snake(Naming.demodulise(type)).to_sym)`),
            // `belongs_to` a bare alias of `has_one`. Confirmed real:
            // banking.bluebook's own `OnboardingCase` (`belongs_to
            // Customer` mints a plain `customer` attribute, not
            // `customer_id`).
            "has_one" | "belongs_to" => {
                let target_raw = super::positional_constant(file, line, gated.row.word, &gated.args, 1)?;
                let target = naming::demodulise(target_raw);
                let as_name = super::named_symbol(&gated.args, "as").unwrap_or_else(|| naming::snake(&target));
                aggregate.attributes.push(references::reference_attribute(&target, Some(&as_name), false));
            }
            // `has_many` — the SAME sugar, but `reference_to(Naming
            // .singularize(plural), as: as || Naming.snake(plural).to_sym)`:
            // the TARGET named is singularized (`has_many Invoices` points
            // at `Invoice`) while the minted attribute's own name keeps
            // the PLURAL spelling as written. Declared in syntax.bluebook
            // but not exercised by any real corpus member yet — built
            // anyway (identical shape to `has_one` above, near-zero extra
            // risk), kept correct rather than left a guess.
            "has_many" => {
                let plural_raw = super::positional_constant(file, line, "has_many", &gated.args, 1)?;
                let plural = naming::demodulise(plural_raw);
                let target = naming::singularize(&plural);
                let as_name = super::named_symbol(&gated.args, "as").unwrap_or_else(|| naming::snake(&plural));
                aggregate.attributes.push(references::reference_attribute(&target, Some(&as_name), false));
            }
            // THE AGGREGATE BOUNDARY (S10, ADR 0025 — "Rules") — the same
            // `source`-body capture `value_object::parse_body`'s own
            // `invariant` arm already does, one level up (that module's
            // own header explains the two legal spellings).
            "invariant" => {
                let description = super::positional_text(file, line, "invariant", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                aggregate.invariants.push(ir::Given { description: Some(description), canonical: canonical::apply(&raw) });
            }
            // A PRECONDITION SHARED ACROSS COMMANDS, DECLARED ONCE (S10,
            // ADR 0025) — block REQUIRED here (`syntax.bluebook`'s own
            // row: only ONE row for `given`/Aggregate, `body: "source"`)
            // — a fresh declaration, never a bare reference; only a
            // COMMAND's own `given` can omit the block (`parse::command`'s
            // own header explains why that form needs no Rust code of its
            // own). DECLARATION-ONLY — Rust never resolves a command's
            // own block-less `given` back against this list; see
            // `ir::Aggregate.preconditions`'s own comment.
            "given" => {
                let description = super::positional_text(file, line, "given", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                aggregate.preconditions.push(ir::Given { description: Some(description), canonical: canonical::apply(&raw) });
            }
            // A FIELD READ THROUGH A REFERENCE, HELD LOCALLY (S12, ADR
            // 0025 — "Consistency across aggregate boundaries") —
            // `from:` names a dotted path, split on the LAST "." the
            // same way `AggregateBuilder#projects`'s own
            // `from.to_s.rpartition(".")` does: `reference` is
            // everything before it, `remote_field` the bare name
            // after. TARGET-side resolution (does the reference
            // actually resolve, does the remote aggregate actually
            // declare that field) stays Ruby-DSL-builder-only, the
            // same as a command's own block-less `given` above —
            // `BluebookBuilder#validate_projected_fields!` needs the
            // WHOLE chapter assembled, which this single-aggregate
            // parse never has.
            "projects" => {
                let field_name = super::positional_symbol(file, line, "projects", &gated.args, 1)?;
                let from = super::named_symbol(&gated.args, "from")
                    .ok_or_else(|| Diagnostic::new(file, line, "'projects' requires a from:"))?;
                let Some((reference, remote_field)) = from.rsplit_once('.') else {
                    return Err(Diagnostic::new(file, line, format!("'projects' from: '{from}' is not reference.field")));
                };
                aggregate.projected_fields.push(ir::ProjectedField {
                    name: field_name,
                    reference: reference.to_string(),
                    remote_field: remote_field.to_string(),
                });
            }
            "value_object" => {
                let vo_name = super::positional_text(file, line, "value_object", &gated.args, 1)?;
                let vo = super::parse_nested_body(file, lines, pos, &gated.call.opener, line, |f, l, p| value_object::parse_body(f, l, p, &vo_name))?;
                aggregate.value_objects.push(vo);
            }
            "lifecycle" => {
                let field = super::positional_symbol(file, line, "lifecycle", &gated.args, 1)?;
                let default = super::named_text(&gated.args, "default")
                    .ok_or_else(|| Diagnostic::new(file, line, "'lifecycle' requires a default:"))?;
                aggregate.lifecycle = Some(lifecycle::parse_body(file, lines, pos, &field, &default)?);
            }
            "entity" => {
                let e_name = super::positional_text(file, line, "entity", &gated.args, 1)?;
                // `AggregateBuilder#entity`'s own `owner_value_objects:
                // @value_objects + closed_sets` — whatever this aggregate
                // has declared SO FAR (textual order), not the whole
                // eventual set; an entity's own TYPE-form `identified_by`
                // resolves against exactly this slice.
                let owner_value_objects: Vec<ir::ValueObject> = aggregate.value_objects.iter().cloned().chain(closed_sets.iter().cloned()).collect();
                aggregate.entities.push(entity::parse_body(file, lines, pos, &e_name, &owner_value_objects)?);
            }
            "query" => {
                let q_name = super::positional_text(file, line, "query", &gated.args, 1)?;
                aggregate.queries.push(query::parse_body(file, lines, pos, &q_name)?);
            }
            "command" => {
                let c_name = super::positional_text(file, line, "command", &gated.args, 1)?;
                let from = command::parse_from(file, line, &gated.args)?;
                // `aggregate.preconditions` AS DECLARED SO FAR (textual
                // order) — see `command::try_reference_named_given`'s own
                // header on why a command's own block-less `given` needs
                // this, not just `&[]`.
                aggregate.commands.push(command::parse_body(file, lines, pos, &c_name, name, from, &aggregate.preconditions)?);
            }
            // `AggregateBuilder#policy` — see this function's own header
            // on why the built `ir::Policy` is returned rather than
            // folded into `aggregate` itself.
            "policy" => {
                let p_name = super::positional_text(file, line, "policy", &gated.args, 1)?;
                policies.push(policy::parse_body(file, lines, pos, &p_name)?);
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
            super::PendingIdentity::Type { line, target, as_field, insert_at } => {
                aggregate.identified_by =
                    identity::resolve_identity_type(file, line, name, &target, as_field.as_deref(), insert_at, &aggregate.value_objects, &mut aggregate.attributes)?;
            }
            super::PendingIdentity::Fields { line, names } => {
                aggregate.identified_by = names
                    .iter()
                    .map(|field| identity::resolve_identity_field(file, line, name, field, &aggregate.value_objects, &aggregate.attributes))
                    .collect::<crate::diag::ParseResult<Vec<String>>>()?;
            }
            super::PendingIdentity::Paths(paths) => aggregate.identified_by = paths,
        }
    }

    Ok((aggregate, policies))
}
