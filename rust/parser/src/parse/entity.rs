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
//! single-path identities, both TYPE and block/Paths forms). S17, ADR
//! 0026 added a sixth: `entity`, nesting a piece inside a piece
//! (`Dispatch`, inside `Handler`, reaction.bluebook) — "no `value_object`,
//! no `policy`, no nested `entity`, no `reference_to`" is no longer
//! quite the whole list ; `reference_to` is still the one real omission.
//! ADR 0028 added a seventh word: `given`, a precondition shared across
//! this piece's OWN commands, declared once — the SAME move
//! `parse::aggregate`'s own `given` arm already makes, one level up
//! (real corpus motivation: banking.bluebook's own `LedgerEntry`, whose
//! `Amend`/`Reverse` used to repeat two `given` blocks byte for byte).

use super::{command, lifecycle, query};
use crate::build::identity;
use crate::canonical;
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
///
/// `entity_named_givens` — see `docs/resolution-rules/cross-entity-given.md`
/// (the mirrored resolution rule's own spec) and `parse::aggregate`'s own
/// header. ONE growing `Vec`, owned by the root aggregate, threaded as a
/// mutable borrow through every piece nested under it however deep (S17's
/// own recursion) — `EntityBuilder#given`'s Ruby-side write-through
/// (`@owner_named_givens[description] ||= named`), mirrored here as
/// "push only if no earlier entry already carries this description"
/// since Rust has no `Hash#||=` to reach for. A SIBLING piece's own
/// command reads it back via `command::try_reference_named_given`'s new
/// second lookup.
pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
    owner_value_objects: &[ir::ValueObject],
    entity_named_givens: &mut Vec<ir::Given>,
) -> ParseResult<ir::Entity> {
    let mut entity = ir::Entity { name: name.to_string(), ..Default::default() };
    let mut pending_identity: Option<super::PendingIdentity> = None;
    // DEFERRED CONSTRUCTION — see `parse::mod::PendingBody`'s own header
    // and `parse::aggregate`'s own mirror, one level up. `command`/
    // `query`/`entity` only QUEUE here; the drain below builds them for
    // real once THIS piece's own top-level line-range is fully walked,
    // so a nested command's own `sets :list, append: {...}` can resolve
    // against a SIBLING piece (S17, ADR 0026 — `entity` nested inside
    // `entity`) regardless of which was written first, matching
    // `EntityBuilder#drain_pending!` exactly.
    let mut pending_entities: Vec<(String, super::PendingBody)> = Vec::new();
    let mut pending_commands: Vec<(String, Option<ir::CommandFrom>, super::PendingBody)> = Vec::new();
    let mut pending_queries: Vec<(String, super::PendingBody)> = Vec::new();

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
            // A PRECONDITION SHARED ACROSS THIS PIECE'S OWN COMMANDS,
            // DECLARED ONCE (ADR 0028) — the SAME move `parse::aggregate`'s
            // own "given" arm already makes, one level up (block REQUIRED
            // here, same reasoning: a fresh declaration, never a bare
            // reference — only a COMMAND's own `given` can omit the
            // block). DECLARATION-ONLY — a command's own bare
            // `given("...")` resolves against this list via
            // `command::parse_body`'s own `preconditions` parameter,
            // threaded through below, mirroring
            // `EntityBuilder#given`/`#drain_pending!` passing its own
            // `@named_givens` into `CommandBuilder.build`.
            "given" => {
                let description = super::positional_text(file, line, "given", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                let built = ir::Given { description: Some(description.clone()), canonical: canonical::apply(&raw) };
                entity.preconditions.push(built.clone());
                // WRITE-THROUGH, first-declared-wins — see this function's
                // own header.
                if !entity_named_givens.iter().any(|g| g.description.as_deref() == Some(description.as_str())) {
                    entity_named_givens.push(built);
                }
            }
            // Round 7 — A PIECE'S OWN SHAPE RULE, checked against EVERY
            // instance of this piece the aggregate holds — the SAME
            // move `parse::aggregate`'s own "invariant" arm already
            // makes, one level down. Block REQUIRED (no reference-by-
            // name form, matching `EntityBuilder#invariant`'s own
            // Ruby-side comment: no known corpus need for a piece's own
            // invariant to be shared with a sibling piece yet).
            "invariant" => {
                let description = super::positional_text(file, line, "invariant", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                entity.invariants.push(ir::Given { description: Some(description), canonical: canonical::apply(&raw) });
            }
            "command" => {
                let c_name = super::positional_text(file, line, "command", &gated.args, 1)?;
                let from = command::parse_from(file, line, &gated.args)?;
                let pending = super::defer_body(file, lines, pos, &gated.call.opener, line)?;
                pending_commands.push((c_name, from, pending));
            }
            "query" => {
                let q_name = super::positional_text(file, line, "query", &gated.args, 1)?;
                let pending = super::defer_body(file, lines, pos, &gated.call.opener, line)?;
                pending_queries.push((q_name, pending));
            }
            // S17, ADR 0026 — a piece nested inside a piece (Dispatch,
            // inside Handler). `owner_value_objects` passes straight
            // through UNCHANGED, not re-derived from this entity's own
            // attributes — a piece mints no value objects of its own at
            // any depth (`EntityBuilder#entity`'s own comment: "there is
            // exactly one pool, however deep the nesting goes"), the
            // same reason `AggregateBuilder`'s own "entity" arm above
            // builds its slice once and hands it to every entity at
            // that level, unchanged.
            "entity" => {
                let e_name = super::positional_text(file, line, "entity", &gated.args, 1)?;
                let pending = super::defer_body(file, lines, pos, &gated.call.opener, line)?;
                pending_entities.push((e_name, pending));
            }
            _ => return Err(super::not_built_yet("Entity", gated.row, file, line, &gated.call.word)),
        }
    }

    // DEFERRED CONSTRUCTION, DRAINED — `EntityBuilder#drain_pending!`'s
    // own mirror: entities first and fully (recursively — a nested piece
    // may itself queue pieces of its own), then commands (so a sibling
    // command's own append-field resolution sees every sibling entity,
    // not just ones declared textually before it), then queries.
    // `owner_value_objects` passes straight through unchanged at every
    // depth — see the "entity" match arm's own comment above.
    // AN EXPLICIT LOOP, not `.into_iter().map(...).collect()` — every
    // OTHER `pending_*` drain in this file stays a `.map()` (no shared
    // mutable state to thread), but this one needs `entity_named_givens`
    // reborrowed sequentially into each nested piece's own recursive
    // `parse_body` call, one at a time, so a LATER-declared sibling can
    // see an EARLIER sibling's own write-through (the same textual-order
    // dependency `AggregateBuilder#drain_pending!`'s own sequential
    // `.map` already gives Ruby, for the identical reason).
    let mut nested_entities = Vec::with_capacity(pending_entities.len());
    for (e_name, pending) in pending_entities {
        let built = super::build_deferred(file, lines, &pending, |f, l, p| parse_body(f, l, p, &e_name, owner_value_objects, entity_named_givens))?;
        nested_entities.push(built);
    }
    entity.entities = nested_entities;

    // ADR 0028 — an entity now offers its OWN preconditions, the same
    // way an aggregate always has (`EntityBuilder#command` now forwards
    // `named_givens: @named_givens`, mirroring `AggregateBuilder#
    // command`'s own `named_givens: @named_givens` one level up) — a
    // bare `given(...)` inside one of THIS entity's own commands
    // resolves against `entity.preconditions`, declared textually so far
    // (the same ordering caveat `parse::aggregate`'s own call already
    // carries), via `command::try_reference_named_given`. `entity_named_
    // givens` (immutably borrowed here — every recursive write above has
    // already finished) is the SAME cross-entity fallback pool
    // `parse::aggregate`'s own call passes as `&[]` for an aggregate-
    // owned command, real here for a piece-owned one.
    let entity_named_givens_slice: &[ir::Given] = entity_named_givens.as_slice();
    entity.commands = pending_commands
        .into_iter()
        .map(|(c_name, from, pending)| {
            super::build_deferred(file, lines, &pending, |f, l, p| {
                command::parse_body(
                    f,
                    l,
                    p,
                    &c_name,
                    name,
                    from.clone(),
                    &entity.preconditions,
                    entity_named_givens_slice,
                    &entity.attributes,
                    owner_value_objects,
                    &entity.entities,
                )
            })
        })
        .collect::<ParseResult<Vec<_>>>()?;

    entity.queries = pending_queries
        .into_iter()
        .map(|(q_name, pending)| super::build_deferred(file, lines, &pending, |f, l, p| query::parse_body(f, l, p, &q_name)))
        .collect::<ParseResult<Vec<_>>>()?;

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
