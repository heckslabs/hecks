//! The `Entity` construct (`lib/hecks/bluebook/ir/entity.rb`, built
//! by `Hecks::Bluebook::DSL::EntityBuilder`) — a piece of an
//! aggregate with an identity of its own. Stage 4: `EntityBuilder`
//! `include AttributeCollector`, the same module `AggregateBuilder` does,
//! and its own `identified_by` is (per its own comment) "the aggregate's
//! method line for line" — so this mirrors `parse::aggregate`'s own
//! `identified_by` handling exactly, via the shared `parse::
//! parse_identified_by`/`PendingIdentity` (`parse::mod`'s own header) —
//! not a second, parallel copy. A piece says less than a head
//! (syntax.bluebook's own comment): no `value_object`, no `policy`, no
//! nested `entity`, no `reference_to` — the words an entity actually
//! declares are `description`/`identified_by`/`attribute`/`command`/
//! `query`/`lifecycle`, confirmed real by banking.bluebook's own
//! `LedgerEntry`/`Withdrawal`/`Visit`/`KeyIssuance` (composite and
//! single-path identities, both type and block/Paths forms). S17, ADR
//! 0026 added a sixth: `entity`, nesting a piece inside a piece
//! (`Dispatch`, inside `Handler`, reaction.bluebook) — "no `value_object`,
//! no `policy`, no nested `entity`, no `reference_to`" is no longer
//! quite the whole list ; `reference_to` is still the one real omission.
//! ADR 0028 added a seventh word: `given`, a precondition shared across
//! this piece's own commands, declared once — the same move
//! `parse::aggregate`'s own `given` arm already makes, one level up
//! (real corpus motivation: banking.bluebook's own `LedgerEntry`, whose
//! `Amend`/`Reverse` share two `given` blocks by name instead of each
//! repeating them byte for byte).
//!
//! **A fourth `given` scope** — chapter-wide, entity-scoped sharing, one
//! level below `parse::aggregate`'s own chapter-wide sharing
//! (`try_reference_named_chapter_given`) — lets two different
//! aggregates' own nested entities share a predicate across the
//! aggregate boundary, mirroring `EntityBuilder#given_impl`'s own
//! `declared_by:` bare-reference form exactly one level down. Real
//! corpus motivation: `Account::LedgerEntry` and
//! `SafeDepositBox::Visit` — two pieces under two different aggregates —
//! independently typed the identical `given("customer is active") {
//! parent.customer.status == "active" }`; `Visit` now instead spells
//! `given("customer is active", declared_by: "Account.LedgerEntry")`.
//! See `try_reference_named_chapter_entity_given`'s own header for the
//! resolution algorithm and `PendingChapterEntityGiven`'s own header for
//! how a chapter split across files is handled.

use super::{command, lifecycle, query};
use crate::build::{identity, naming, references};
use crate::canonical;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{self, LineShape, Opener, SourceLine};

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Entity.{word}"))
}

/// Bare `given(desc)` — chapter-wide, entity-scoped reference. Mirrors
/// `parse::aggregate::ChapterGivenLookup`/`try_reference_named_chapter_
/// given` exactly, one level down: peeks the next physical line without
/// consuming it unless it actually matches (word `given`, `Opener::
/// None`) — a fresh `given("x") { ... }` declaration, or any other word
/// entirely, falls through untouched to the ordinary `next_line` gate.
///
/// Keyed by (owner "AggregateName.EntityName", `Given`) pairs — the same
/// disambiguation `AggregateBuilder#given_impl`'s own chapter-wide pool
/// needs, one level down: two different pieces (anywhere in the
/// chapter) can independently declare the same description under a
/// genuinely different canonical, so an optional `declared_by:
/// "Aggregate.Entity"` argument picks the exact owner when more than
/// one candidate is registered; omitted, it resolves only when exactly
/// one candidate exists.
///
/// `declared_by:` is a plain string here, never a constant — unlike
/// `Aggregate`'s own `declared_by:` (a real aggregate constant), a piece
/// has no first-class, independently-addressable reference anywhere in
/// this language (entity.bluebook's own `ArgumentSeed` row for this
/// argument declares `kind: "text"`, not `kind: "constant"` — checked
/// live by `verify_resolves_via`/`argument_gate` against that same
/// table).
///
/// A chapter may be split across files — "not found among `chapter_
/// entity_named_givens` so far" is not immediately refused, only genuine
/// ambiguity is; `ChapterEntityGivenLookup::Pending` carries everything
/// the final pass (`parse::chapter::parse_chapter`'s own resolution
/// loop, after every file has contributed) needs to resolve it for real.
pub enum ChapterEntityGivenLookup {
    Resolved(ir::Given),
    Pending {
        description: String,
        declared_by: Option<String>,
        file: String,
        line: usize,
    },
}

fn try_reference_named_chapter_entity_given(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    chapter_entity_named_givens: &[(String, ir::Given)],
) -> ParseResult<Option<ChapterEntityGivenLookup>> {
    let Some(&line) = lines.get(*pos) else {
        return Ok(None);
    };
    let LineShape::Call(call) = lex::classify(file, &line)? else {
        return Ok(None);
    };
    if call.word != "given" || !matches!(call.opener, Opener::None) {
        return Ok(None);
    }

    super::verify_resolves_via(file, line.number, "given", "Entity", "owner_keyed")?;

    let args = super::argument_gate(file, "given", "Entity", &call.args, line.number)?;
    let description = super::positional_text(file, line.number, "given", &args, 1)?;
    let declared_by = super::named_text(&args, "declared_by");

    let candidates: Vec<&(String, ir::Given)> = chapter_entity_named_givens
        .iter()
        .filter(|(_, given)| given.description.as_deref() == Some(description.as_str()))
        .collect();

    let resolved = if let Some(owner) = declared_by {
        match candidates
            .iter()
            .find(|(candidate_owner, _)| candidate_owner == &owner)
        {
            Some((_, given)) => ChapterEntityGivenLookup::Resolved(given.clone()),
            None => ChapterEntityGivenLookup::Pending {
                description,
                declared_by: Some(owner),
                file: file.to_string(),
                line: line.number,
            },
        }
    } else {
        match candidates.as_slice() {
            [] => ChapterEntityGivenLookup::Pending {
                description,
                declared_by: None,
                file: file.to_string(),
                line: line.number,
            },
            [(_, given)] => ChapterEntityGivenLookup::Resolved(given.clone()),
            _ => {
                let owners: Vec<&str> =
                    candidates.iter().map(|(owner, _)| owner.as_str()).collect();
                return Err(Diagnostic::new(
                    file,
                    line.number,
                    format!(
                        "'{description}' is ambiguous across the chapter's own pieces — {} \
                         each declare a DIFFERENT predicate under this same description; name \
                         which one with declared_by:",
                        owners.join(", ")
                    ),
                ));
            }
        }
    };

    *pos += 1;
    Ok(Some(resolved))
}

/// One entry per unresolved bare chapter-entity-given some entity in this
/// aggregate's own file left pending. `entity_path` locates which entity,
/// however deeply nested (S17, ADR 0026) — built bottom-up as this
/// struct bubbles from the entity that actually declared it, through
/// every enclosing `entity::parse_body`/`aggregate::parse_body` call, up
/// to `parse::chapter::parse_chapter`'s own final resolution pass: each
/// level prepends its own index into the `Vec<ir::Entity>` this entity
/// lands in, so the finished path reads left-to-right from the
/// aggregate's own `entities` down to the exact (possibly nested) piece.
/// `precondition_index` names where in that entity's own `preconditions`
/// the eventual real `Given` gets patched in.
pub struct PendingChapterEntityGiven {
    pub entity_path: Vec<usize>,
    pub precondition_index: usize,
    pub description: String,
    pub declared_by: Option<String>,
    pub file: String,
    pub line: usize,
}

/// **One level deeper still** — a command owned by some entity in this
/// aggregate, bare-referencing the same not-yet-resolved chapter-entity-
/// given its own owning entity left pending (`command::
/// PendingCommandGiven`'s own comment: `command::try_reference_named_
/// given` already recognizes an empty-canonical placeholder in its
/// owner's `preconditions` and defers rather than freezing it). Resolved
/// in a pass after every `PendingChapterEntityGiven` above has already
/// patched its owning entity's own `preconditions` — this one copies
/// that result. `entity_path` is the path to the owning entity (the same
/// shape `PendingChapterEntityGiven`'s own field is); `inner.given_index`
/// /`inner.precondition_index` are relative to that same entity.
pub struct PendingEntityCommandGiven {
    pub entity_path: Vec<usize>,
    pub command_index: usize,
    pub inner: command::PendingCommandGiven,
}

/// Navigates `entities` down an `entity_path` (see `PendingChapterEntity
/// Given`'s own comment) to a mutable reference to the entity it names —
/// shared by `parse::chapter::parse_chapter`'s own final resolution pass
/// for both pending kinds above. Panics on an empty path or an
/// out-of-range index — both would mean a path was built wrong
/// somewhere in this file, never a malformed source file (nothing here
/// reads untrusted input; every path comes from this module's own
/// bookkeeping).
pub fn entity_at_path_mut<'a>(
    entities: &'a mut [ir::Entity],
    path: &[usize],
) -> &'a mut ir::Entity {
    let (first, rest) = path
        .split_first()
        .expect("entity_path must have at least one segment");
    let entity = &mut entities[*first];
    if rest.is_empty() {
        entity
    } else {
        entity_at_path_mut(&mut entity.entities, rest)
    }
}

/// Parses an `entity "Name" do ... end` body. `owner_value_objects` is
/// the owning aggregate's own `@value_objects + closed_sets` at the point
/// `entity` was called (`AggregateBuilder#entity`'s own comment) — an
/// entity holds none of its own, so a type-form `identified_by` here
/// (`identified_by LedgerSequence, as: :sequence`) resolves against the
/// aggregate's, exactly like `EntityBuilder#resolve_pending_identity!`
/// does with the `owner_value_objects:` it was constructed with.
///
/// `entity_named_givens` — see `docs/resolution-rules/cross-entity-given.md`
/// (the mirrored resolution rule's own spec) and `parse::aggregate`'s own
/// header. One growing `Vec`, owned by the root aggregate, threaded as a
/// mutable borrow through every piece nested under it however deep (S17's
/// own recursion) — `EntityBuilder#given`'s Ruby-side write-through
/// (`@owner_named_givens[description] ||= named`), mirrored here as
/// "push only if no earlier entry already carries this description"
/// since Rust has no `Hash#||=` to reach for. A sibling piece's own
/// command reads it back via `command::try_reference_named_given`'s new
/// second lookup.
pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
    identity_name_prefix: &str,
    owner_value_objects: &mut Vec<ir::ValueObject>,
    identity_value_object_insert_at: &mut usize,
    entity_named_givens: &mut Vec<ir::Given>,
    // **One level wider still** — see this module's own header and
    // `PendingChapterEntityGiven`'s own comment. `aggregate_name` names
    // this piece's own root, so the write-through below can key itself
    // "AggregateName.EntityName" — the same dotted addressing
    // `declared_by:` already uses one level up. `chapter_entity_named_
    // givens` is the root of the pool — one `Vec`, owned by
    // `parse::chapter::parse_chapter`, threaded unchanged through every
    // aggregate and every piece nested under it however deep.
    aggregate_name: &str,
    chapter_entity_named_givens: &mut Vec<(String, ir::Given)>,
) -> ParseResult<(
    ir::Entity,
    Vec<PendingChapterEntityGiven>,
    Vec<PendingEntityCommandGiven>,
)> {
    let mut entity = ir::Entity {
        name: name.to_string(),
        ..Default::default()
    };
    let mut pending_identity: Option<super::PendingIdentity> = None;
    // Every bare chapter-entity-given this piece (or any piece nested
    // under it) left pending — see `PendingChapterEntityGiven`'s own
    // comment for what each entry means and where it drains.
    let mut pending_chapter_entity_givens: Vec<PendingChapterEntityGiven> = Vec::new();
    // **One level deeper** — a command (owned by this piece, or by one nested
    // under it) bare-referencing the same not-yet-resolved placeholder —
    // see `PendingEntityCommandGiven`'s own comment.
    let mut pending_entity_command_givens: Vec<PendingEntityCommandGiven> = Vec::new();
    // **Deferred construction** — see `parse::mod::PendingBody`'s own header
    // and `parse::aggregate`'s own mirror, one level up. `command`/
    // `query`/`entity` only queue here; the drain below builds them for
    // real once this piece's own top-level line-range is fully walked,
    // so a nested command's own `sets :list, append: {...}` can resolve
    // against a sibling piece (S17, ADR 0026 — `entity` nested inside
    // `entity`) regardless of which was written first, matching
    // `EntityBuilder#drain_pending!` exactly.
    let mut pending_entities: Vec<(String, super::PendingBody)> = Vec::new();
    let mut pending_commands: Vec<(String, Option<ir::CommandFrom>, super::PendingBody)> =
        Vec::new();
    let mut pending_queries: Vec<(String, super::PendingBody)> = Vec::new();

    loop {
        // Bare `given(desc)` — chapter-wide, entity-scoped reference —
        // peeked before the ordinary grammar-gated `next_line` below, the
        // identical trick `parse::aggregate`'s own loop already uses one
        // level up: entity.bluebook's own grammar row for `given`/Entity
        // still declares `body: "source"` (block required) — a genuinely
        // bare `given` has to be recognized and consumed here, by raw
        // lexing, before that gate would refuse it.
        if let Some(outcome) = try_reference_named_chapter_entity_given(
            file,
            lines,
            pos,
            chapter_entity_named_givens,
        )? {
            match outcome {
                ChapterEntityGivenLookup::Resolved(given) => {
                    entity.preconditions.push(given.clone());
                    // **Write-through** — the same cross-entity fallback pool
                    // the block form already writes through to, below.
                    if !entity_named_givens
                        .iter()
                        .any(|g| g.description == given.description)
                    {
                        entity_named_givens.push(given);
                    }
                }
                ChapterEntityGivenLookup::Pending {
                    description,
                    declared_by,
                    file,
                    line,
                } => {
                    let precondition_index = entity.preconditions.len();
                    // **A placeholder** — see `parse::aggregate`'s own
                    // identical placeholder for why an empty `canonical`
                    // is a safe "still pending" sentinel. Deliberately
                    // not written through to `entity_named_givens` here
                    // — a sibling piece under this same aggregate reading
                    // the fallback pool before this placeholder resolves
                    // would clone a permanently-empty canonical with no
                    // further chance to patch it (unlike Ruby, which
                    // aliases the same mutable object into both pools).
                    // Not exercised by any real corpus member today: the
                    // one case that shows up (`SafeDepositBox::Visit`
                    // referencing `Account::LedgerEntry`) resolves
                    // immediately, since the declaring file loads first —
                    // see this module's own header.
                    entity.preconditions.push(ir::Given {
                        description: Some(description.clone()),
                        canonical: String::new(),
                    });
                    pending_chapter_entity_givens.push(PendingChapterEntityGiven {
                        entity_path: Vec::new(),
                        precondition_index,
                        description,
                        declared_by,
                        file,
                        line,
                    });
                }
            }
            continue;
        }

        let Some(gated) = super::next_line(file, lines, pos, "Entity")? else {
            break;
        };
        let line = gated.line.number;

        match gated.row.word {
            "description" => {
                entity.description = Some(super::positional_text(
                    file,
                    line,
                    "description",
                    &gated.args,
                    1,
                )?)
            }
            "attribute" => entity
                .attributes
                .push(super::build_attribute(file, line, "attribute", &gated.args)?.0),
            "identified_by" => {
                if pending_identity.is_some() {
                    return Err(Diagnostic::new(
                        file,
                        line,
                        format!("{name} declares identified_by more than once"),
                    ));
                }
                let inline_type_name = format!("{identity_name_prefix}Identity");
                let parsed = super::parse_identified_by(
                    file,
                    lines,
                    pos,
                    line,
                    &gated.args,
                    &gated.call.opener,
                    entity.attributes.len(),
                    &inline_type_name,
                    owner_value_objects.as_slice(),
                )?;
                pending_identity = Some(match parsed {
                    super::PendingIdentity::Inline {
                        line,
                        value_object,
                        as_field,
                        insert_at,
                    } => {
                        if owner_value_objects
                            .iter()
                            .any(|existing| existing.name == value_object.name)
                        {
                            return Err(Diagnostic::new(
                                file,
                                line,
                                format!(
                                    "{name}.identified_by synthesizes duplicate value object {}",
                                    value_object.name
                                ),
                            ));
                        }
                        let target = value_object.name.clone();
                        let index =
                            (*identity_value_object_insert_at).min(owner_value_objects.len());
                        owner_value_objects.insert(index, value_object);
                        *identity_value_object_insert_at += 1;
                        super::PendingIdentity::Type {
                            line,
                            target,
                            as_field: Some(as_field.unwrap_or_else(|| "identity".to_string())),
                            insert_at,
                        }
                    }
                    other => other,
                });
            }
            "reference_to" => {
                let target_raw =
                    super::positional_constant(file, line, "reference_to", &gated.args, 1)?;
                let target = naming::demodulise(target_raw);
                let as_name = super::named_symbol(&gated.args, "as");
                let optional = super::named_flag(&gated.args, "optional");
                entity.attributes.push(references::relationship_attribute(
                    &target,
                    "reference_to",
                    as_name.as_deref(),
                    optional,
                    false,
                ));
            }
            "has_one" | "belongs_to" => {
                let target_raw =
                    super::positional_constant(file, line, gated.row.word, &gated.args, 1)?;
                let target = naming::demodulise(target_raw);
                let as_name = super::named_symbol(&gated.args, "as")
                    .unwrap_or_else(|| naming::snake(&target));
                let optional = super::named_flag(&gated.args, "optional");
                entity.attributes.push(references::relationship_attribute(
                    &target,
                    gated.row.word,
                    Some(&as_name),
                    optional,
                    false,
                ));
            }
            "has_many" => {
                let plural_raw =
                    super::positional_constant(file, line, "has_many", &gated.args, 1)?;
                let plural = naming::demodulise(plural_raw);
                let target = naming::singularize(&plural);
                let as_name = super::named_symbol(&gated.args, "as")
                    .unwrap_or_else(|| naming::snake(&plural));
                let optional = super::named_flag(&gated.args, "optional");
                entity.attributes.push(references::relationship_attribute(
                    &target,
                    "has_many",
                    Some(&as_name),
                    optional,
                    true,
                ));
            }
            "lifecycle" => {
                let field = super::positional_symbol(file, line, "lifecycle", &gated.args, 1)?;
                let default = super::named_text(&gated.args, "default").ok_or_else(|| {
                    Diagnostic::new(file, line, "'lifecycle' requires a default:")
                })?;
                entity.lifecycle = Some(lifecycle::parse_body(file, lines, pos, &field, &default)?);
            }
            // A precondition shared across this piece's own commands,
            // declared once (ADR 0028) — the same move `parse::aggregate`'s
            // own "given" arm already makes, one level up (block required
            // here, same reasoning: a fresh declaration, never a bare
            // reference — only a command's own `given` can omit the
            // block). Declaration-only — a command's own bare
            // `given("...")` resolves against this list via
            // `command::parse_body`'s own `preconditions` parameter,
            // threaded through below, mirroring
            // `EntityBuilder#given`/`#drain_pending!` passing its own
            // `@named_givens` into `CommandBuilder.build`.
            "given" => {
                let description = super::positional_text(file, line, "given", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                let built = ir::Given {
                    description: Some(description.clone()),
                    canonical: canonical::apply(&raw),
                };
                entity.preconditions.push(built.clone());
                // Write-through, first-declared-wins — see this function's
                // own header.
                if !entity_named_givens
                    .iter()
                    .any(|g| g.description.as_deref() == Some(description.as_str()))
                {
                    entity_named_givens.push(built.clone());
                }
                // **Write-through, per owner** — the chapter-wide analogue of
                // the line above, keyed by ["AggregateName.EntityName",
                // description] rather than description alone — see this
                // module's own header and `parse::aggregate`'s own
                // identical chapter write-through, one level up.
                let owner = format!("{aggregate_name}.{name}");
                if !chapter_entity_named_givens.iter().any(|(candidate_owner, g)| {
                    candidate_owner == &owner && g.description.as_deref() == Some(description.as_str())
                }) {
                    chapter_entity_named_givens.push((owner, built));
                }
            }
            // Round 7 — a piece's own shape rule, checked against every
            // instance of this piece the aggregate holds — the same
            // move `parse::aggregate`'s own "invariant" arm already
            // makes, one level down. Block required (no reference-by-
            // name form, matching `EntityBuilder#invariant`'s own
            // Ruby-side comment: no known corpus need for a piece's own
            // invariant to be shared with a sibling piece yet).
            "invariant" => {
                let description = super::positional_text(file, line, "invariant", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                entity.invariants.push(ir::Given {
                    description: Some(description),
                    canonical: canonical::apply(&raw),
                });
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
            // through unchanged, not re-derived from this entity's own
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
            _ => {
                return Err(super::not_built_yet(
                    "Entity",
                    gated.row,
                    file,
                    line,
                    &gated.call.word,
                ))
            }
        }
    }

    // **Deferred construction, drained** — `EntityBuilder#drain_pending!`'s
    // own mirror: entities first and fully (recursively — a nested piece
    // may itself queue pieces of its own), then commands (so a sibling
    // command's own append-field resolution sees every sibling entity,
    // not just ones declared textually before it), then queries.
    // `owner_value_objects` passes straight through unchanged at every
    // depth — see the "entity" match arm's own comment above.
    // An explicit loop, not `.into_iter().map(...).collect()` — every
    // other `pending_*` drain in this file stays a `.map()` (no shared
    // mutable state to thread), but this one needs `entity_named_givens`
    // reborrowed sequentially into each nested piece's own recursive
    // `parse_body` call, one at a time, so a later-declared sibling can
    // see an earlier sibling's own write-through (the same textual-order
    // dependency `AggregateBuilder#drain_pending!`'s own sequential
    // `.map` already gives Ruby, for the identical reason).
    let mut nested_entities = Vec::with_capacity(pending_entities.len());
    for (e_name, pending) in pending_entities {
        let nested_index = nested_entities.len();
        let (built, child_pending_given, child_pending_command) =
            super::build_deferred(file, lines, &pending, |f, l, p| {
                parse_body(
                    f,
                    l,
                    p,
                    &e_name,
                    &format!("{}{}", identity_name_prefix, naming::demodulise(&e_name)),
                    owner_value_objects,
                    identity_value_object_insert_at,
                    entity_named_givens,
                    aggregate_name,
                    chapter_entity_named_givens,
                )
            })?;
        nested_entities.push(built);
        // Bubble up, prepending this level's own index — see
        // `PendingChapterEntityGiven`'s own header on why `entity_path`
        // is built bottom-up, one prepend per enclosing level.
        pending_chapter_entity_givens.extend(child_pending_given.into_iter().map(|mut entry| {
            entry.entity_path.insert(0, nested_index);
            entry
        }));
        pending_entity_command_givens.extend(child_pending_command.into_iter().map(|mut entry| {
            entry.entity_path.insert(0, nested_index);
            entry
        }));
    }
    entity.entities = nested_entities;

    // ADR 0028 — an entity now offers its own preconditions, the same
    // way an aggregate always has (`EntityBuilder#command` now forwards
    // `named_givens: @named_givens`, mirroring `AggregateBuilder#
    // command`'s own `named_givens: @named_givens` one level up) — a
    // bare `given(...)` inside one of this entity's own commands
    // resolves against `entity.preconditions`, declared textually so far
    // (the same ordering caveat `parse::aggregate`'s own call already
    // carries), via `command::try_reference_named_given`. `entity_named_
    // givens` (immutably borrowed here — every recursive write above has
    // already finished) is the same cross-entity fallback pool
    // `parse::aggregate`'s own call passes as `&[]` for an aggregate-
    // owned command, real here for a piece-owned one.
    let entity_named_givens_slice: &[ir::Given] = entity_named_givens.as_slice();
    // An explicit loop, not `.map().collect()` — this one needs
    // `pending_entity_command_givens` mutated per-command (index-stamped
    // as it goes), the same reason the nested-entity drain above is an
    // explicit loop too. `command::parse_body` now also returns any
    // pending bare given reference it left for later
    // (`PendingCommandGiven`'s own comment): `preconditions` above is
    // `&entity.preconditions`, which — unlike before this construct
    // existed — can now hold a chapter-entity-given placeholder (this
    // entity's own bare `given(...)`, still unresolved). No longer
    // discarded; bubbled up as `PendingEntityCommandGiven`, stamped with
    // this entity's own path (`entity_path: Vec::new()` here — the
    // caller, if any, prepends its own index the same way the nested-
    // entity drain above does).
    let mut entity_commands = Vec::with_capacity(pending_commands.len());
    for (command_index, (c_name, from, pending)) in pending_commands.into_iter().enumerate() {
        let (built, pending_given) = super::build_deferred(file, lines, &pending, |f, l, p| {
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
                owner_value_objects.as_slice(),
                &entity.entities,
            )
        })?;
        pending_entity_command_givens.extend(pending_given.into_iter().map(|inner| {
            PendingEntityCommandGiven {
                entity_path: Vec::new(),
                command_index,
                inner,
            }
        }));
        entity_commands.push(built);
    }
    entity.commands = entity_commands;

    entity.queries = pending_queries
        .into_iter()
        .map(|(q_name, pending)| {
            super::build_deferred(file, lines, &pending, |f, l, p| {
                query::parse_body(f, l, p, &q_name)
            })
        })
        .collect::<ParseResult<Vec<_>>>()?;

    if let Some(pending) = pending_identity {
        match pending {
            super::PendingIdentity::Type {
                line,
                target,
                as_field,
                insert_at,
            } => {
                entity.identified_by = identity::resolve_identity_type(
                    file,
                    line,
                    name,
                    &target,
                    as_field.as_deref(),
                    insert_at,
                    owner_value_objects.as_slice(),
                    &mut entity.attributes,
                )?;
            }
            super::PendingIdentity::Fields { line, names } => {
                let mut paths = Vec::new();
                for field in &names {
                    paths.extend(identity::resolve_identity_field(
                        file,
                        line,
                        name,
                        field,
                        owner_value_objects.as_slice(),
                        &entity.attributes,
                    )?);
                }
                entity.identified_by = paths;
            }
            super::PendingIdentity::Inline { .. } => unreachable!(
                "inline identities are installed and converted to named identities while parsing"
            ),
        }
    }

    lifecycle::seal_commands(file, *pos, &entity.name, entity.lifecycle.as_ref(), &entity.commands)?;

    Ok((
        entity,
        pending_chapter_entity_givens,
        pending_entity_command_givens,
    ))
}
