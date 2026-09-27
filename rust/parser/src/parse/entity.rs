//! The `Entity` construct: a piece of an aggregate with an identity of its own.
//! `identified_by` and `given` handling mirror `parse::aggregate`, one level down.

use super::{command, lifecycle, query};
use crate::build::{identity, naming, references};
use crate::canonical;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{self, LineShape, Opener, SourceLine};

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Entity.{word}"))
}

/// Outcome of looking up a bare `given(desc)` among the chapter's entity-scoped givens.
///
/// `Pending` defers to the final pass in `parse::chapter::parse_chapter`, since a chapter may be
/// split across files. `declared_by:` is plain text: a piece has no addressable constant.
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

/// A bare chapter-entity-given left unresolved. `entity_path` indexes down through nested
/// entities; each enclosing level prepends its own index as the entry bubbles up.
pub struct PendingChapterEntityGiven {
    pub entity_path: Vec<usize>,
    pub precondition_index: usize,
    pub description: String,
    pub declared_by: Option<String>,
    pub file: String,
    pub line: usize,
}

/// A command's bare reference to a still-pending chapter-entity-given, resolved after every
/// `PendingChapterEntityGiven` has patched its owning entity's `preconditions`.
pub struct PendingEntityCommandGiven {
    pub entity_path: Vec<usize>,
    pub command_index: usize,
    pub inner: command::PendingCommandGiven,
}

/// Navigates `entities` down `path` to the entity it names.
///
/// # Panics
/// On an empty path or out-of-range index; paths are built internally, never from input.
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

/// Parses an `entity "Name" do ... end` body.
///
/// `owner_value_objects` is the owning aggregate's pool: an entity holds none of its own, so a
/// type-form `identified_by` resolves against it. `entity_named_givens` is one pool shared by
/// every piece under the root aggregate; a sibling's command reads it back through
/// `command::try_reference_named_given`.
pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
    identity_name_prefix: &str,
    owner_value_objects: &mut Vec<ir::ValueObject>,
    identity_value_object_insert_at: &mut usize,
    entity_named_givens: &mut Vec<ir::Given>,
    // `aggregate_name` keys chapter-wide givens as "Aggregate.Entity"; the pool is threaded
    // unchanged through every nested piece.
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
    let mut pending_chapter_entity_givens: Vec<PendingChapterEntityGiven> = Vec::new();
    let mut pending_entity_command_givens: Vec<PendingEntityCommandGiven> = Vec::new();
    // Bodies are queued and built after the walk so a nested command can resolve against
    // a sibling piece regardless of declaration order. (ADR 0026)
    let mut pending_entities: Vec<(String, super::PendingBody)> = Vec::new();
    let mut pending_commands: Vec<(String, Option<ir::CommandFrom>, super::PendingBody)> =
        Vec::new();
    let mut pending_queries: Vec<(String, super::PendingBody)> = Vec::new();

    loop {
        // Peeked before `next_line`: the grammar row still requires a block for `given`, so a
        // bare reference must be consumed here.
        if let Some(outcome) = try_reference_named_chapter_entity_given(
            file,
            lines,
            pos,
            chapter_entity_named_givens,
        )? {
            match outcome {
                ChapterEntityGivenLookup::Resolved(given) => {
                    entity.preconditions.push(given.clone());
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
                    // Empty `canonical` marks the placeholder as pending. Not written through
                    // to `entity_named_givens`: a sibling would clone the empty canonical.
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
            // Block required: a fresh declaration; only a command's own `given` may be bare.
            "given" => {
                let description = super::positional_text(file, line, "given", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                let built = ir::Given {
                    description: Some(description.clone()),
                    canonical: canonical::apply(&raw),
                };
                entity.preconditions.push(built.clone());
                if !entity_named_givens
                    .iter()
                    .any(|g| g.description.as_deref() == Some(description.as_str()))
                {
                    entity_named_givens.push(built.clone());
                }
                // Chapter-wide pool, keyed by "Aggregate.Entity" plus description.
                let owner = format!("{aggregate_name}.{name}");
                if !chapter_entity_named_givens.iter().any(|(candidate_owner, g)| {
                    candidate_owner == &owner && g.description.as_deref() == Some(description.as_str())
                }) {
                    chapter_entity_named_givens.push((owner, built));
                }
            }
            // Block required; no reference-by-name form, as no corpus case shares an invariant.
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
            // `owner_value_objects` passes through unchanged: a piece mints no value objects at
            // any depth.
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

    // Drain order: entities first (recursively), then commands so a command sees every
    // sibling entity, then queries. An explicit loop, not `map`: each nested parse reborrows
    // `entity_named_givens`, so later siblings see earlier ones' write-through.
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

    // A bare `given` in this entity's commands resolves against `entity.preconditions`, then
    // the cross-entity `entity_named_givens` pool. (ADR 0028)
    let entity_named_givens_slice: &[ir::Given] = entity_named_givens.as_slice();
    // Explicit loop: `pending_entity_command_givens` is stamped with each command's index.
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
