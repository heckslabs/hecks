//! Parses the `Aggregate` construct (`Hecks::Bluebook::DSL::AggregateBuilder`).
//! Nested policies are returned separately, not folded into `ir::Aggregate`.

use super::{command, entity, lifecycle, policy, query, value_object};
use crate::build::{identity, naming, references};
use crate::canonical;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{self, LineShape, Opener, SourceLine};
use crate::ruby_value;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Aggregate.{word}"))
}

/// Outcome of a bare chapter-wide `given(desc)` reference.
///
/// A chapter may span files, so an undeclared target is `Pending`, settled by
/// `parse::chapter::parse_chapter` once every file has loaded. Ambiguity is refused at once.
pub enum ChapterGivenLookup {
    Resolved(ir::Given),
    Pending {
        description: String,
        declared_by: Option<String>,
        file: String,
        line: usize,
    },
}

fn try_reference_named_chapter_given(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    chapter_named_givens: &[(String, ir::Given)],
) -> ParseResult<Option<ChapterGivenLookup>> {
    let Some(&line) = lines.get(*pos) else {
        return Ok(None);
    };
    let LineShape::Call(call) = lex::classify(file, &line)? else {
        return Ok(None);
    };
    if call.word != "given" || !matches!(call.opener, Opener::None) {
        return Ok(None);
    }

    super::verify_resolves_via(file, line.number, "given", "Aggregate", "owner_keyed")?;

    let args = super::argument_gate(file, "given", "Aggregate", &call.args, line.number)?;
    let description = super::positional_text(file, line.number, "given", &args, 1)?;
    let declared_by =
        super::named_raw(&args, "declared_by").map(|raw| naming::demodulise(raw.trim()));

    let candidates: Vec<&(String, ir::Given)> = chapter_named_givens
        .iter()
        .filter(|(_, given)| given.description.as_deref() == Some(description.as_str()))
        .collect();

    let resolved = if let Some(owner) = declared_by {
        match candidates
            .iter()
            .find(|(candidate_owner, _)| candidate_owner == &owner)
        {
            Some((_, given)) => ChapterGivenLookup::Resolved(given.clone()),
            None => ChapterGivenLookup::Pending {
                description,
                declared_by: Some(owner),
                file: file.to_string(),
                line: line.number,
            },
        }
    } else {
        match candidates.as_slice() {
            [] => ChapterGivenLookup::Pending {
                description,
                declared_by: None,
                file: file.to_string(),
                line: line.number,
            },
            [(_, given)] => ChapterGivenLookup::Resolved(given.clone()),
            _ => {
                let owners: Vec<&str> =
                    candidates.iter().map(|(owner, _)| owner.as_str()).collect();
                return Err(Diagnostic::new(
                    file,
                    line.number,
                    format!(
                        "'{description}' is ambiguous in this chapter — {} each declare a \
                         DIFFERENT predicate under this same description; name which one with \
                         declared_by:",
                        owners.join(", ")
                    ),
                ));
            }
        }
    };

    *pos += 1;
    Ok(Some(resolved))
}

/// A bare chapter-given left unresolved; `parse::chapter::parse_chapter` patches the real
/// `Given` into `preconditions[precondition_index]`.
pub struct PendingChapterGiven {
    pub precondition_index: usize,
    pub description: String,
    pub declared_by: Option<String>,
    pub file: String,
    pub line: usize,
}
/// Type-form `identified_by` resolves after the loop: its value object may be declared later.
pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
    chapter_named_givens: &mut Vec<(String, ir::Given)>,
    // Chapter-wide entity-scoped pool, passed unchanged to every top-level entity.
    chapter_entity_named_givens: &mut Vec<(String, ir::Given)>,
) -> ParseResult<(
    ir::Aggregate,
    Vec<ir::Policy>,
    Vec<PendingChapterGiven>,
    Vec<(usize, command::PendingCommandGiven)>,
    Vec<entity::PendingChapterEntityGiven>,
    Vec<entity::PendingEntityCommandGiven>,
)> {
    let mut aggregate = ir::Aggregate {
        name: name.to_string(),
        ..Default::default()
    };
    let mut pending_identity: Option<super::PendingIdentity> = None;
    let mut closed_sets: Vec<ir::ValueObject> = Vec::new();
    let mut policies: Vec<ir::Policy> = Vec::new();
    let mut pending_chapter_givens: Vec<PendingChapterGiven> = Vec::new();
    // `entity_path` is relative to `aggregate.entities`; the entity drain loop stamps it.
    let mut pending_chapter_entity_givens: Vec<entity::PendingChapterEntityGiven> = Vec::new();
    let mut pending_entity_command_givens: Vec<entity::PendingEntityCommandGiven> = Vec::new();
    // Entities, commands and queries are queued, then built after the loop once
    // `value_objects`, `entities`, `preconditions` and `attributes` are final.
    let mut pending_entities: Vec<(String, super::PendingBody)> = Vec::new();
    let mut pending_commands: Vec<(String, Option<ir::CommandFrom>, super::PendingBody)> =
        Vec::new();
    let mut pending_queries: Vec<(String, super::PendingBody)> = Vec::new();
    // Root of the cross-entity given pool. Empty for this aggregate's own commands.
    let mut entity_named_givens: Vec<ir::Given> = Vec::new();

    loop {
        // Bare `given(desc)` is peeked before `next_line`: the grammar row for `given` requires
        // a block, so a bare reference must be consumed here.
        if let Some(outcome) =
            try_reference_named_chapter_given(file, lines, pos, chapter_named_givens)?
        {
            match outcome {
                ChapterGivenLookup::Resolved(given) => aggregate.preconditions.push(given),
                ChapterGivenLookup::Pending {
                    description,
                    declared_by,
                    file,
                    line,
                } => {
                    let precondition_index = aggregate.preconditions.len();
                    // Placeholder; `parse_chapter` overwrites this slot after every file loads.
                    aggregate.preconditions.push(ir::Given {
                        description: Some(description.clone()),
                        canonical: String::new(),
                    });
                    pending_chapter_givens.push(PendingChapterGiven {
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

        let Some(gated) = super::next_line(file, lines, pos, "Aggregate")? else {
            break;
        };
        let line = gated.line.number;

        match gated.row.word {
            "description" => {
                aggregate.description = Some(super::positional_text(
                    file,
                    line,
                    "description",
                    &gated.args,
                    1,
                )?)
            }
            // Origin, not identity: captured raw, like a literal Hash default.
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
                if pending_identity.is_some() {
                    return Err(Diagnostic::new(
                        file,
                        line,
                        format!("{name} declares identified_by more than once"),
                    ));
                }
                let inline_type_name = format!("{}Identity", naming::demodulise(name));
                let owner_value_objects: Vec<ir::ValueObject> = aggregate
                    .value_objects
                    .iter()
                    .chain(closed_sets.iter())
                    .cloned()
                    .collect();
                let parsed = super::parse_identified_by(
                    file,
                    lines,
                    pos,
                    line,
                    &gated.args,
                    &gated.call.opener,
                    aggregate.attributes.len(),
                    &inline_type_name,
                    &owner_value_objects,
                )?;
                pending_identity = Some(match parsed {
                    super::PendingIdentity::Inline {
                        line,
                        value_object,
                        as_field,
                        insert_at,
                    } => {
                        if aggregate
                            .value_objects
                            .iter()
                            .chain(closed_sets.iter())
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
                        aggregate.value_objects.push(value_object);
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
            // Mints a reference attribute; unlike the command form, never an `acts_on`.
            "reference_to" => {
                let target_raw =
                    super::positional_constant(file, line, "reference_to", &gated.args, 1)?;
                let target = naming::demodulise(target_raw);
                let as_name = super::named_symbol(&gated.args, "as");
                let optional = super::named_flag(&gated.args, "optional");
                aggregate
                    .attributes
                    .push(references::relationship_attribute(
                        &target,
                        "reference_to",
                        as_name.as_deref(),
                        optional,
                        false,
                    ));
            }
            // Sugar over `reference_to` with no `_id` suffix; `belongs_to` is an alias.
            "has_one" | "belongs_to" => {
                let target_raw =
                    super::positional_constant(file, line, gated.row.word, &gated.args, 1)?;
                let target = naming::demodulise(target_raw);
                let as_name = super::named_symbol(&gated.args, "as")
                    .unwrap_or_else(|| naming::snake(&target));
                let optional = super::named_flag(&gated.args, "optional");
                aggregate
                    .attributes
                    .push(references::relationship_attribute(
                        &target,
                        gated.row.word,
                        Some(&as_name),
                        optional,
                        false,
                    ));
            }
            // Singularizes the target (`has_many Invoices` -> `Invoice`); the name stays plural.
            "has_many" => {
                let plural_raw =
                    super::positional_constant(file, line, "has_many", &gated.args, 1)?;
                let plural = naming::demodulise(plural_raw);
                let target = naming::singularize(&plural);
                let as_name = super::named_symbol(&gated.args, "as")
                    .unwrap_or_else(|| naming::snake(&plural));
                let optional = super::named_flag(&gated.args, "optional");
                aggregate
                    .attributes
                    .push(references::relationship_attribute(
                        &target,
                        "has_many",
                        Some(&as_name),
                        optional,
                        true,
                    ));
            }
            // Aggregate-level invariant; same source-body capture as `value_object::parse_body`.
            "invariant" => {
                let description = super::positional_text(file, line, "invariant", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                aggregate.invariants.push(ir::Given {
                    description: Some(description),
                    canonical: canonical::apply(&raw),
                });
            }
            // A fresh declaration needs a block; bare references are consumed before `next_line`.
            "given" => {
                let description = super::positional_text(file, line, "given", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                let built = ir::Given {
                    description: Some(description.clone()),
                    canonical: canonical::apply(&raw),
                };
                aggregate.preconditions.push(built.clone());
                // First declaration wins per (owner, description); other owners add own.
                if !chapter_named_givens.iter().any(|(owner, g)| {
                    owner == name && g.description.as_deref() == Some(description.as_str())
                }) {
                    chapter_named_givens.push((name.to_string(), built));
                }
            }
            // `from:` is a dotted path split on the last `.`. Resolving the remote field needs the
            // whole chapter, so it stays with the Ruby builder.
            "projects" => {
                let field_name = super::positional_symbol(file, line, "projects", &gated.args, 1)?;
                let from = super::named_symbol(&gated.args, "from")
                    .ok_or_else(|| Diagnostic::new(file, line, "'projects' requires a from:"))?;
                let Some((reference, remote_field)) = from.rsplit_once('.') else {
                    return Err(Diagnostic::new(
                        file,
                        line,
                        format!("'projects' from: '{from}' is not reference.field"),
                    ));
                };
                aggregate.projected_fields.push(ir::ProjectedField {
                    name: field_name,
                    reference: reference.to_string(),
                    remote_field: remote_field.to_string(),
                });
            }
            // Block form declares attributes; `value_object "Price", Integer` declares `value`.
            // `body_gate` picked the row. Type plus block is refused below: the argument rows are
            // shared, so the gate cannot see the body.
            "value_object" => {
                let vo_name = super::positional_text(file, line, "value_object", &gated.args, 1)?;
                let type_arg = gated
                    .args
                    .positional
                    .iter()
                    .find(|(idx, _)| *idx == 2)
                    .map(|(_, text)| text.clone());

                if gated.row.body == "none" {
                    let attributes = match type_arg {
                        Some(text) => {
                            let (type_name, list, closed_set) = super::resolve_type_expression(
                                file,
                                line,
                                "value_object",
                                "value",
                                &text,
                            )?;
                            if let Some(vo) = closed_set {
                                closed_sets.push(vo);
                            }
                            vec![ir::Attribute {
                                name: "value".to_string(),
                                type_name,
                                list,
                                default: None,
                                optional: false,
                                pattern: None,
                                admits: None,
                                relationship: None,
                            }]
                        }
                        None => Vec::new(),
                    };
                    aggregate.value_objects.push(ir::ValueObject {
                        name: vo_name,
                        attributes,
                        invariants: Vec::new(),
                        closed_set: false,
                        members: Vec::new(),
                    });
                } else {
                    if type_arg.is_some() {
                        return Err(Diagnostic::new(
                            file,
                            line,
                            format!(
                                "{vo_name} declares both a type and a block — value_object \
                                 \"{vo_name}\", Type is sugar for a block declaring exactly one \
                                 attribute named :value; write one form or the other, never both"
                            ),
                        ));
                    }
                    let owner_value_objects: Vec<ir::ValueObject> = aggregate
                        .value_objects
                        .iter()
                        .chain(closed_sets.iter())
                        .cloned()
                        .collect();
                    let (vo, nested_sets) = super::parse_nested_body(
                        file,
                        lines,
                        pos,
                        &gated.call.opener,
                        line,
                        |f, l, p| value_object::parse_body(f, l, p, &vo_name, &owner_value_objects),
                    )?;
                    aggregate.value_objects.push(vo);
                    aggregate.value_objects.extend(nested_sets);
                }
            }
            "lifecycle" => {
                let field = super::positional_symbol(file, line, "lifecycle", &gated.args, 1)?;
                let default = super::named_text(&gated.args, "default").ok_or_else(|| {
                    Diagnostic::new(file, line, "'lifecycle' requires a default:")
                })?;
                aggregate.lifecycle =
                    Some(lifecycle::parse_body(file, lines, pos, &field, &default)?);
            }
            // Queued; built in the drain below against the complete `value_objects`.
            "entity" => {
                let e_name = super::positional_text(file, line, "entity", &gated.args, 1)?;
                let pending = super::defer_body(file, lines, pos, &gated.call.opener, line)?;
                pending_entities.push((e_name, pending));
            }
            "query" => {
                let q_name = super::positional_text(file, line, "query", &gated.args, 1)?;
                let pending = super::defer_body(file, lines, pos, &gated.call.opener, line)?;
                pending_queries.push((q_name, pending));
            }
            "command" => {
                let c_name = super::positional_text(file, line, "command", &gated.args, 1)?;
                let from = command::parse_from(file, line, &gated.args)?;
                let pending = super::defer_body(file, lines, pos, &gated.call.opener, line)?;
                pending_commands.push((c_name, from, pending));
            }
            "policy" => {
                let p_name = super::positional_text(file, line, "policy", &gated.args, 1)?;
                policies.push(policy::parse_body(file, lines, pos, &p_name)?);
            }
            _ => {
                return Err(super::not_built_yet(
                    "Aggregate",
                    gated.row,
                    file,
                    line,
                    &gated.call.word,
                ))
            }
        }
    }

    // Closed sets follow explicit value objects, before identity resolves (Ruby's order).
    let mut identity_value_object_insert_at = aggregate.value_objects.len();
    aggregate.value_objects.extend(closed_sets);

    // Drain queued bodies in Ruby's order (entities, commands, queries), after `value_objects`.
    // An explicit loop so `entity_named_givens` reborrows sequentially and later siblings see
    // earlier writes.
    let mut entities = Vec::with_capacity(pending_entities.len());
    for (e_name, pending) in pending_entities {
        let entity_index = entities.len();
        let (built, child_pending_given, child_pending_command) =
            super::build_deferred(file, lines, &pending, |f, l, p| {
                entity::parse_body(
                    f,
                    l,
                    p,
                    &e_name,
                    &format!(
                        "{}{}",
                        naming::demodulise(name),
                        naming::demodulise(&e_name)
                    ),
                    &mut aggregate.value_objects,
                    &mut identity_value_object_insert_at,
                    &mut entity_named_givens,
                    name,
                    chapter_entity_named_givens,
                )
            })?;
        entities.push(built);
        // Prepend this entity's index; `entity_path` is built bottom-up.
        pending_chapter_entity_givens.extend(child_pending_given.into_iter().map(|mut entry| {
            entry.entity_path.insert(0, entity_index);
            entry
        }));
        pending_entity_command_givens.extend(child_pending_command.into_iter().map(|mut entry| {
            entry.entity_path.insert(0, entity_index);
            entry
        }));
    }
    aggregate.entities = entities;

    let built_commands: Vec<(ir::Command, Vec<command::PendingCommandGiven>)> = pending_commands
        .into_iter()
        .map(|(c_name, from, pending_body)| {
            super::build_deferred(file, lines, &pending_body, |f, l, p| {
                command::parse_body(
                    f,
                    l,
                    p,
                    &c_name,
                    name,
                    from.clone(),
                    &aggregate.preconditions,
                    &[],
                    &aggregate.attributes,
                    &aggregate.value_objects,
                    &aggregate.entities,
                )
            })
        })
        .collect::<ParseResult<Vec<_>>>()?;

    // Stamp each pending command-given with its command index, known only here.
    let mut pending_command_givens: Vec<(usize, command::PendingCommandGiven)> = Vec::new();
    aggregate.commands = built_commands
        .into_iter()
        .enumerate()
        .map(|(command_index, (built, pending))| {
            pending_command_givens.extend(pending.into_iter().map(|entry| (command_index, entry)));
            built
        })
        .collect();

    aggregate.queries = pending_queries
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
                aggregate.identified_by = identity::resolve_identity_type(
                    file,
                    line,
                    name,
                    &target,
                    as_field.as_deref(),
                    insert_at,
                    &aggregate.value_objects,
                    &mut aggregate.attributes,
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
                        &aggregate.value_objects,
                        &aggregate.attributes,
                    )?);
                }
                aggregate.identified_by = paths;
            }
            super::PendingIdentity::Inline { .. } => unreachable!(
                "inline identities are installed and converted to named identities while parsing"
            ),
        }
    }

    lifecycle::seal_commands(file, *pos, &aggregate.name, aggregate.lifecycle.as_ref(), &aggregate.commands)?;

    Ok((
        aggregate,
        policies,
        pending_chapter_givens,
        pending_command_givens,
        pending_chapter_entity_givens,
        pending_entity_command_givens,
    ))
}
