//! The `Bluebook` construct and the driver for `hecks-parse chapter`.
//! Parses each `.bluebook` file into one `ir::Bluebook`, then applies `.hecksagon` files onto it.

use super::{aggregate, command, entity, policy, process_manager, read_model};
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{self, SourceLine};

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Bluebook.{word}"))
}

/// Parses one chapter across one or more `.bluebook` files plus any `.hecksagon` files.
/// Stops at the first diagnostic, whichever file it comes from.
pub fn parse_chapter(chapter_name: &str, files: &[(String, String)]) -> ParseResult<ir::Bluebook> {
    if files.is_empty() {
        return Err(Diagnostic::new(
            "<none>",
            0,
            "hecks-parse chapter requires at least one file",
        ));
    }

    let mut bluebook: Option<ir::Bluebook> = None;
    let mut aggregate_policies: Vec<ir::Policy> = Vec::new();
    let mut chapter_policies: Vec<ir::Policy> = Vec::new();
    let mut chapter_named_givens: Vec<(String, ir::Given)> = Vec::new();
    // Bare chapter-givens deferred until every file has loaded.
    let mut pending_chapter_givens: Vec<(usize, aggregate::PendingChapterGiven)> = Vec::new();
    // A command's bare reference to a deferred chapter-given, resolved after the aggregate pass.
    let mut pending_command_givens: Vec<(usize, usize, command::PendingCommandGiven)> = Vec::new();
    // Chapter-wide pool of entity-scoped givens.
    let mut chapter_entity_named_givens: Vec<(String, ir::Given)> = Vec::new();
    // Bare entity-given references deferred until every file has loaded.
    let mut pending_chapter_entity_givens: Vec<(usize, entity::PendingChapterEntityGiven)> =
        Vec::new();
    // Entity-owned commands referencing a deferred entity-given; resolved after the entity pass.
    let mut pending_entity_command_givens: Vec<(usize, entity::PendingEntityCommandGiven)> =
        Vec::new();
    let mut hecksagon_files: Vec<&(String, String)> = Vec::new();

    for entry @ (path, source) in files {
        let joined = lex::join_continuations(source);
        let lines = lex::lines(&joined);
        let mut pos = 0usize;
        let (row, call, header_line) = super::file::parse_header(path, &lines, &mut pos)?;

        if let Some(declared_name) = super::file::header_name(&call) {
            if row.inner == "Bluebook" && declared_name != chapter_name {
                return Err(Diagnostic::new(
                    path,
                    header_line,
                    format!("--chapter {chapter_name} was requested, but this file declares '{declared_name}'"),
                ));
            }
        }

        match row.inner {
            "Bluebook" => {
                let declared_version = super::file::header_version(&call);
                if bluebook.is_none() {
                    let mut built = ir::Bluebook {
                        name: chapter_name.to_string(),
                        ..Default::default()
                    };
                    built.version = declared_version.clone();
                    bluebook = Some(built);
                }
                let target = bluebook.as_mut().expect("just set above");
                if let Some(version) = declared_version {
                    match target.version.as_deref() {
                        Some(existing) if existing != version => {
                            return Err(Diagnostic::new(
                                path,
                                header_line,
                                format!("{chapter_name} declares both version {existing:?} and {version:?}"),
                            ));
                        }
                        None => target.version = Some(version),
                        _ => {}
                    }
                }
                parse_body_into(
                    path,
                    &lines,
                    &mut pos,
                    target,
                    &mut aggregate_policies,
                    &mut chapter_policies,
                    &mut chapter_named_givens,
                    &mut pending_chapter_givens,
                    &mut pending_command_givens,
                    &mut chapter_entity_named_givens,
                    &mut pending_chapter_entity_givens,
                    &mut pending_entity_command_givens,
                )?;
            }
            "Hecksagon" => hecksagon_files.push(entry),
            "" => return Err(not_implemented(path, header_line, &call.word)),
            other => {
                return Err(Diagnostic::new(
                    path,
                    header_line,
                    format!("hecks-parse chapter reads .bluebook/.hecksagon files ('bluebook'/'hecksagon'); got '{}' (inner context '{other}')", call.word),
                ));
            }
        }
    }

    let mut bluebook = bluebook.ok_or_else(|| {
        Diagnostic::new(
            "<none>",
            0,
            format!("no .bluebook file given for chapter '{chapter_name}'"),
        )
    })?;

    // Aggregate policies first, then chapter-level ones, as `BluebookBuilder#build` orders them.
    bluebook.policies = aggregate_policies;
    bluebook.policies.extend(chapter_policies);

    // Reference-hop query tails resolve only once the whole aggregate graph exists.
    crate::build::query_inference::apply(&files[0].0, &mut bluebook)?;

    // Resolves deferred chapter-given references now that every file's declarations are known.
    // Patches by index; a command's own copy is resolved in the next pass.
    for (aggregate_index, pending) in pending_chapter_givens {
        let candidates: Vec<&(String, ir::Given)> = chapter_named_givens
            .iter()
            .filter(|(_, given)| given.description.as_deref() == Some(pending.description.as_str()))
            .collect();

        let resolved = if let Some(owner) = &pending.declared_by {
            candidates
                .iter()
                .find(|(candidate_owner, _)| candidate_owner == owner)
                .map(|(_, given)| given.clone())
                .ok_or_else(|| {
                    Diagnostic::new(
                        &pending.file,
                        pending.line,
                        format!(
                            "'{}' names no precondition {owner} declares in this chapter — {owner} \
                             either hasn't declared '{}', or declared_by: named the wrong aggregate",
                            pending.description, pending.description
                        ),
                    )
                })?
        } else {
            match candidates.as_slice() {
                [] => {
                    return Err(Diagnostic::new(
                        &pending.file,
                        pending.line,
                        format!(
                        "'{}' names no precondition any aggregate in this chapter ever declares \
                             — declare it once with a block",
                        pending.description
                    ),
                    ))
                }
                [(_, given)] => given.clone(),
                _ => {
                    let owners: Vec<&str> =
                        candidates.iter().map(|(owner, _)| owner.as_str()).collect();
                    return Err(Diagnostic::new(
                        &pending.file,
                        pending.line,
                        format!(
                            "'{}' is ambiguous in this chapter — {} each declare a DIFFERENT \
                             predicate under this same description; name which one with declared_by:",
                            pending.description,
                            owners.join(", ")
                        ),
                    ));
                }
            }
        };

        bluebook.aggregates[aggregate_index].preconditions[pending.precondition_index] = resolved;
    }

    // Copies the aggregate's resolved precondition, so it must run after the pass above.
    for (aggregate_index, command_index, pending) in pending_command_givens {
        let resolved =
            bluebook.aggregates[aggregate_index].preconditions[pending.precondition_index].clone();
        bluebook.aggregates[aggregate_index].commands[command_index].givens[pending.given_index] =
            resolved;
    }

    // Entity-scoped analogue of the pass above; `entity_at_path_mut` finds the nested entity.
    for (aggregate_index, pending) in pending_chapter_entity_givens {
        let candidates: Vec<&(String, ir::Given)> = chapter_entity_named_givens
            .iter()
            .filter(|(_, given)| given.description.as_deref() == Some(pending.description.as_str()))
            .collect();

        let resolved = if let Some(owner) = &pending.declared_by {
            candidates
                .iter()
                .find(|(candidate_owner, _)| candidate_owner == owner)
                .map(|(_, given)| given.clone())
                .ok_or_else(|| {
                    Diagnostic::new(
                        &pending.file,
                        pending.line,
                        format!(
                            "'{}' names no precondition {owner} declares in this chapter — {owner} \
                             either hasn't declared '{}', or declared_by: named the wrong piece",
                            pending.description, pending.description
                        ),
                    )
                })?
        } else {
            match candidates.as_slice() {
                [] => {
                    return Err(Diagnostic::new(
                        &pending.file,
                        pending.line,
                        format!(
                            "'{}' names no precondition any piece in this chapter ever declares \
                             — declare it once with a block",
                            pending.description
                        ),
                    ))
                }
                [(_, given)] => given.clone(),
                _ => {
                    let owners: Vec<&str> =
                        candidates.iter().map(|(owner, _)| owner.as_str()).collect();
                    return Err(Diagnostic::new(
                        &pending.file,
                        pending.line,
                        format!(
                            "'{}' is ambiguous across the chapter's own pieces — {} each declare \
                             a DIFFERENT predicate under this same description; name which one \
                             with declared_by:",
                            pending.description,
                            owners.join(", ")
                        ),
                    ));
                }
            }
        };

        let target_entity = entity::entity_at_path_mut(
            &mut bluebook.aggregates[aggregate_index].entities,
            &pending.entity_path,
        );
        target_entity.preconditions[pending.precondition_index] = resolved;
    }

    // Copies the owning entity's resolved precondition, so it must run after the pass above.
    for (aggregate_index, pending) in pending_entity_command_givens {
        let target_entity = entity::entity_at_path_mut(
            &mut bluebook.aggregates[aggregate_index].entities,
            &pending.entity_path,
        );
        let resolved = target_entity.preconditions[pending.inner.precondition_index].clone();
        target_entity.commands[pending.command_index].givens[pending.inner.given_index] = resolved;
    }

    for (path, source) in hecksagon_files {
        let joined = lex::join_continuations(source);
        let lines = lex::lines(&joined);
        let mut pos = 0usize;

        // One file may hold several `Hecks.hecksagon` blocks; `lex::lines` drops comments.
        while pos < lines.len() {
            let (row, call, header_line) = super::file::parse_header(path, &lines, &mut pos)?;
            if row.inner != "Hecksagon" {
                return Err(Diagnostic::new(
                    path,
                    header_line,
                    format!("a .hecksagon file's own top-level blocks must all be 'hecksagon'; got '{}'", call.word),
                ));
            }

            let declared_name = super::file::header_name(&call);
            if declared_name.as_deref() == Some(chapter_name) {
                super::hecksagon::apply(
                    path,
                    &lines,
                    &mut pos,
                    &mut bluebook,
                    &mut Vec::new(),
                    &mut Vec::new(),
                    true,
                )?;
            } else {
                // Sibling block for another chapter: gated so syntax errors refuse; then dropped.
                let mut discarded = ir::Bluebook::default();
                super::hecksagon::apply(
                    path,
                    &lines,
                    &mut pos,
                    &mut discarded,
                    &mut Vec::new(),
                    &mut Vec::new(),
                    true,
                )?;
            }
        }
    }

    Ok(bluebook)
}

/// Lists the chapters `<Name>`'s block pulls in via `attaches` (or its deprecated spellings).
/// Every block is still gated; the IR accumulator is a throwaway.
pub fn resolve_hecksagon_dependencies(
    chapter_name: &str,
    path: &str,
    source: &str,
) -> ParseResult<(Vec<String>, Vec<String>)> {
    let joined = lex::join_continuations(source);
    let lines = lex::lines(&joined);
    let mut pos = 0usize;
    let mut framework_names: Vec<String> = Vec::new();
    let mut vendored_names: Vec<String> = Vec::new();
    let mut found = false;

    while pos < lines.len() {
        let (row, call, header_line) = super::file::parse_header(path, &lines, &mut pos)?;
        if row.inner != "Hecksagon" {
            return Err(Diagnostic::new(
                path,
                header_line,
                format!(
                    "a .hecksagon file's own top-level blocks must all be 'hecksagon'; got '{}'",
                    call.word
                ),
            ));
        }

        let declared_name = super::file::header_name(&call);
        if declared_name.as_deref() == Some(chapter_name) {
            found = true;
            let mut discarded = ir::Bluebook::default();
            super::hecksagon::apply(
                path,
                &lines,
                &mut pos,
                &mut discarded,
                &mut framework_names,
                &mut vendored_names,
                false,
            )?;
        } else {
            let mut discarded = ir::Bluebook::default();
            super::hecksagon::apply(
                path,
                &lines,
                &mut pos,
                &mut discarded,
                &mut Vec::new(),
                &mut Vec::new(),
                true,
            )?;
        }
    }

    if !found {
        return Err(Diagnostic::new(
            path,
            0,
            format!("no 'Hecks.hecksagon \"{chapter_name}\"' block found in {path}"),
        ));
    }

    Ok((framework_names, vendored_names))
}

/// Parses a `Hecks.bluebook "Name" do ... end` body into an existing accumulator.
/// Policies bubble as in `BluebookBuilder#build`: aggregate policies first, then chapter-level.
fn parse_body_into(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    bluebook: &mut ir::Bluebook,
    aggregate_policies: &mut Vec<ir::Policy>,
    chapter_policies: &mut Vec<ir::Policy>,
    chapter_named_givens: &mut Vec<(String, ir::Given)>,
    pending_chapter_givens: &mut Vec<(usize, aggregate::PendingChapterGiven)>,
    pending_command_givens: &mut Vec<(usize, usize, command::PendingCommandGiven)>,
    chapter_entity_named_givens: &mut Vec<(String, ir::Given)>,
    pending_chapter_entity_givens: &mut Vec<(usize, entity::PendingChapterEntityGiven)>,
    pending_entity_command_givens: &mut Vec<(usize, entity::PendingEntityCommandGiven)>,
) -> ParseResult<()> {
    // The given pool spans the whole chapter, not one file: a later concept file may reference
    // a named given an earlier one declared. Entries are (owner aggregate name, `Given`).
    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Bluebook")? else {
            break;
        };
        let line = gated.line.number;

        match gated.row.word {
            "vision" => {
                bluebook.vision = Some(super::positional_text(
                    file,
                    line,
                    "vision",
                    &gated.args,
                    1,
                )?)
            }
            "namespace" => {
                bluebook.namespace =
                    Some(super::positional_text(file, line, "namespace", &gated.args, 1)?)
            }
            "formerly_known_as" => {
                bluebook.formerly_known_as = Some(super::positional_text(
                    file,
                    line,
                    "formerly_known_as",
                    &gated.args,
                    1,
                )?)
            }
            // One `Provision` row per named argument, in source order; required keys are
            // checked by Ruby's `Validation#validate_provisions!`.
            "provides" => {
                let capability = super::positional_text(file, line, "provides", &gated.args, 1)?;
                for (key, _) in &gated.args.named {
                    let verb = super::named_text(&gated.args, key).unwrap_or_default();
                    bluebook.provides.push(ir::Provision {
                        capability: capability.clone(),
                        key: key.clone(),
                        verb,
                    });
                }
            }
            "core" => bluebook.classification = Some("core".to_string()),
            "supporting" => bluebook.classification = Some("supporting".to_string()),
            "generic" => bluebook.classification = Some("generic".to_string()),
            // Variadic like `group_by`; accumulates because a second `attaches_to` is not refused.
            "attaches_to" => {
                for at in 1..=gated.args.positional.len() {
                    bluebook.attaches_to.push(super::positional_text(
                        file,
                        line,
                        "attaches_to",
                        &gated.args,
                        at,
                    )?);
                }
            }
            "aggregate" => {
                let agg_name = super::positional_text(file, line, "aggregate", &gated.args, 1)?;
                let (
                    built,
                    policies,
                    pending,
                    command_pending,
                    entity_given_pending,
                    entity_command_pending,
                ) = aggregate::parse_body(
                    file,
                    lines,
                    pos,
                    &agg_name,
                    chapter_named_givens,
                    chapter_entity_named_givens,
                )?;
                let aggregate_index = bluebook.aggregates.len();
                bluebook.aggregates.push(built);
                aggregate_policies.extend(policies);
                pending_chapter_givens
                    .extend(pending.into_iter().map(|entry| (aggregate_index, entry)));
                pending_command_givens.extend(
                    command_pending
                        .into_iter()
                        .map(|(command_index, entry)| (aggregate_index, command_index, entry)),
                );
                pending_chapter_entity_givens.extend(
                    entity_given_pending
                        .into_iter()
                        .map(|entry| (aggregate_index, entry)),
                );
                pending_entity_command_givens.extend(
                    entity_command_pending
                        .into_iter()
                        .map(|entry| (aggregate_index, entry)),
                );
            }
            "policy" => {
                let pol_name = super::positional_text(file, line, "policy", &gated.args, 1)?;
                chapter_policies.push(policy::parse_body(file, lines, pos, &pol_name)?);
            }
            "read_model" => {
                let rm_name = super::positional_text(file, line, "read_model", &gated.args, 1)?;
                bluebook
                    .read_models
                    .push(read_model::parse_body(file, lines, pos, &rm_name)?);
            }
            "process_manager" => {
                let pm_name =
                    super::positional_text(file, line, "process_manager", &gated.args, 1)?;
                bluebook
                    .process_managers
                    .push(process_manager::parse_body(file, lines, pos, &pm_name)?);
            }
            _ => {
                return Err(super::not_built_yet(
                    "Bluebook",
                    gated.row,
                    file,
                    line,
                    &gated.call.word,
                ))
            }
        }
    }

    Ok(())
}
