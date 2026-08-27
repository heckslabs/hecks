//! The `Bluebook` construct — the top of the construct chain
//! (`lib/hecks/bluebook/ir/bluebook.rb`), and the driver for
//! `hecks-parse chapter --chapter <Name> <files...>`.
//!
//! Parses each `.bluebook` file's header + body into one `ir::Bluebook`,
//! then applies any `.hecksagon` file(s) given onto the ALREADY-BUILT
//! result (`parse::hecksagon::apply`) — mirroring `bin/project_rust`'s
//! own real load order: the domain's `.bluebook` loads and registers
//! every aggregate FIRST, its `.hecksagon` loads SECOND and mutates
//! those already-registered aggregates (attaching ports).
//!
//! STAGE 6: A CHAPTER SPLIT ACROSS SEVERAL `.bluebook` FILES
//! (`MetaValidator::GRAMMAR_FILES`, discovered concept files sharing one chapter name —
//! the self-hosted language parsing its own grammar) is now real,
//! mirroring `BluebookBuilder.build`'s own accumulating-builder shape
//! (`meta_validator.rb`'s own comment: "`BluebookBuilder.build` keeps
//! one builder open per chapter name across calls ... so loading all
//! the folder in order accumulates one domain"). Concretely: every
//! `Bluebook`-context file's body is parsed into the SAME `ir::Bluebook`
//! accumulator, in file order — `aggregate`/`policy`/`report`/
//! `process_manager` all APPEND across files exactly as they do within
//! one file, while `vision`/`core`/`supporting`/`generic`/
//! `formerly_known_as` (single-value fields) are SET, not reset, by a
//! later file that doesn't mention them — matching
//! `BluebookBuilder#vision`/`#core`/etc.'s own plain `@ivar = value`
//! assignment, never touched by a file that has no such line. The
//! Header metadata belongs to the composed chapter, not the first filename:
//! Ruby's open builder adopts a non-empty `version:` from whichever concept
//! file declares it and refuses conflicting versions. This makes sorted folder
//! discovery independent of a specially ordered metadata file.
//!
//! STAGE 4 finding: a SINGLE `.hecksagon` FILE may declare MORE THAN ONE
//! `Hecks.hecksagon "Name" do ... end` block — banking.hecksagon's own
//! shape, confirmed real: after the `"Banking"` block (the one this
//! chapter's own binds live in), the SAME file also carries sibling
//! `Hecks.hecksagon "Governance" do ... end`/`"Identity"` blocks (their
//! own comment explains why: a persistence bind belongs beside the
//! aggregate whose registry it's found under, not beside whichever
//! domain's own `.hecksagon` happens to `uses_framework` it — so
//! Governance/Identity's OWN binds sit in this same physical file rather
//! than a nonexistent `framework/bluebook/governance.hecksagon`). Every
//! block in the file is still gated for real (fail-closed holds for ALL
//! of them, not just the one this chapter cares about) — only the block
//! whose OWN declared name matches `chapter_name` is applied onto the
//! real `bluebook`; every other one is applied onto a throwaway,
//! discarded `ir::Bluebook`, so a real syntax error inside a sibling
//! block still refuses rather than being silently skipped.

use super::{aggregate, command, policy, process_manager, read_model};
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{self, SourceLine};

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Bluebook.{word}"))
}

/// Parses one chapter across one or more source files — exactly one
/// `.bluebook` file plus zero or more `.hecksagon` files, applied in the
/// order given. Stops at the FIRST diagnostic, whichever file it comes
/// from ("first error aborts" applied across files, not just within
/// one).
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
    // EVERY BARE CHAPTER-GIVEN A FILE PARSED SO FAR LEFT PENDING — see
    // `aggregate::PendingChapterGiven`'s own comment for what queues here
    // and this function's own resolution pass (below) for where it
    // drains, once every file has loaded.
    let mut pending_chapter_givens: Vec<(usize, aggregate::PendingChapterGiven)> = Vec::new();
    // ONE LEVEL DEEPER STILL — a COMMAND's own bare reference to the
    // same not-yet-resolved chapter-given (`command::PendingCommandGiven`
    // 's own comment). Resolved in a SECOND pass below, after every
    // `PendingChapterGiven` above has already patched the aggregate's
    // own `preconditions` — this one COPIES that result rather than
    // re-resolving from scratch.
    let mut pending_command_givens: Vec<(usize, usize, command::PendingCommandGiven)> = Vec::new();
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

    // Combined ONCE, after every Bluebook-context file has contributed —
    // matching `BluebookBuilder#build`'s own `@aggregates.flat_map(&:policies)
    // + @policies`, run only at the very end regardless of how many files
    // fed the accumulator.
    bluebook.policies = aggregate_policies;
    bluebook.policies.extend(chapter_policies);

    // Query arguments inherit their schema from the field they are compared
    // with. Reference-hop tails can only resolve now, once the chapter's
    // complete aggregate graph exists; local paths use this same pass so the
    // inference rule has one implementation and one declaration-order rule.
    crate::build::query_inference::apply(&files[0].0, &mut bluebook)?;

    // THE OTHER HALF OF A CHAPTER-WIDE `given` REFERENCE —
    // `aggregate::try_reference_named_chapter_given` recognised an
    // unresolved bare reference and deferred it here, unable to check
    // further: a later file in this SAME chapter might still declare the
    // real thing. Resolved now, once and for all, against the
    // NOW-COMPLETE `chapter_named_givens` — the IDENTICAL lookup that
    // function already does, just late enough to see every aggregate's
    // own declarations, not only the ones parsed before the referencing
    // one. Mirrors `BluebookBuilder#resolve_pending_chapter_givens!`
    // exactly, one call-site: PATCHES `bluebook.aggregates[aggregate_
    // index].preconditions[precondition_index]` directly rather than
    // mutating a shared object in place (Ruby's own trick, not available
    // here — nothing else in Rust's IR holds a second reference to the
    // placeholder that would need to see the update; the SECOND pass
    // below handles the one thing that does, a command's own copy).
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

    // A THIRD LAYER — a COMMAND's own bare reference to the same
    // description (`command::PendingCommandGiven`'s own comment). Runs
    // AFTER the loop above, on purpose — it COPIES the aggregate's own
    // now-final `preconditions[precondition_index]`, so the aggregate
    // -level placeholder has to be resolved for real first.
    for (aggregate_index, command_index, pending) in pending_command_givens {
        let resolved =
            bluebook.aggregates[aggregate_index].preconditions[pending.precondition_index].clone();
        bluebook.aggregates[aggregate_index].commands[command_index].givens[pending.given_index] =
            resolved;
    }

    for (path, source) in hecksagon_files {
        let joined = lex::join_continuations(source);
        let lines = lex::lines(&joined);
        let mut pos = 0usize;

        // Loop over EVERY top-level `Hecks.hecksagon "Name" do ... end`
        // block in the file — see this module's own header on why one
        // file may hold several. `pos < lines.len()` at the top of each
        // iteration is exactly "did the block we just finished consume
        // the whole file" — `lex::lines` already stripped every comment
        // and blank line, so the NEXT real line (if any) is always
        // another header.
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
                    true,
                )?;
            } else {
                // A SIBLING hecksagon for a DIFFERENT chapter, physically
                // sharing this file (see this module's own header) —
                // still gated for real, its content simply never reaches
                // the real `bluebook`.
                let mut discarded = ir::Bluebook::default();
                super::hecksagon::apply(
                    path,
                    &lines,
                    &mut pos,
                    &mut discarded,
                    &mut Vec::new(),
                    true,
                )?;
            }
        }
    }

    Ok(bluebook)
}

/// STAGE 8 — `hecks-parse resolve --chapter <Name> <file.hecksagon>`'s
/// own driver: which OTHER (framework) chapters `<Name>`'s own block
/// inside this `.hecksagon` file pulls in via `uses_framework`. Reuses
/// the EXACT same "loop over every top-level `Hecks.hecksagon "..." do
/// ... end` block, apply only the one whose own declared name matches,
/// still gate every sibling block for real" shape `parse_chapter`'s own
/// `.hecksagon` loop already established (this module's own header, the
/// STAGE 4 finding on why one file may hold several blocks) — a second,
/// narrower entry point onto the same real parsing, not a second fact
/// base. Every block is still fail-closed gated regardless of whether
/// it matches; `ir::Bluebook::default()` is a throwaway accumulator
/// here (resolve never emits IR), the collected `uses_framework` names
/// are the only thing this function returns.
pub fn resolve_uses_framework(
    chapter_name: &str,
    path: &str,
    source: &str,
) -> ParseResult<Vec<String>> {
    let joined = lex::join_continuations(source);
    let lines = lex::lines(&joined);
    let mut pos = 0usize;
    let mut names: Vec<String> = Vec::new();
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
            super::hecksagon::apply(path, &lines, &mut pos, &mut discarded, &mut names, false)?;
        } else {
            let mut discarded = ir::Bluebook::default();
            super::hecksagon::apply(
                path,
                &lines,
                &mut pos,
                &mut discarded,
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

    Ok(names)
}

/// Parses a `Hecks.bluebook "Name" do ... end` body INTO an
/// already-existing accumulator — `vision`/`core`/`supporting`/
/// `generic`/`formerly_known_as`/`aggregate`/`policy`/`report`/
/// `read_model`. STAGE 4 added `process_manager` (banking.bluebook's own
/// three sagas). `formerly_known_as` is parsed (single positional text,
/// same shape as `vision`) but not exercised by any real corpus member
/// yet — every fixture still emits it as `null`.
///
/// STAGE 6: takes `bluebook`/`aggregate_policies`/`chapter_policies` BY
/// MUTABLE REFERENCE rather than minting and returning fresh ones, so
/// `parse_chapter` can call this once per Bluebook-context FILE while
/// every file appends onto the SAME running totals — the shape
/// `BluebookBuilder`'s own single, registry-memoized builder instance
/// has across the discovered `MetaValidator::GRAMMAR_FILES` calls (see this
/// module's own header). A single-file chapter (pizzas.bluebook, ...)
/// still gets exactly one call, so this is a strict generalization, not
/// a behavior change for every existing REAL_PARITY_MEMBERS entry.
///
/// POLICY BUBBLING ORDER: `BluebookBuilder#build`'s own `policies =
/// @aggregates.flat_map(&:policies) + @policies` — every AGGREGATE's own
/// nested policies, in aggregate declaration order, THEN every
/// CHAPTER-level policy, in ITS OWN declaration order — regardless of how
/// the two kinds interleave in the source text, OR ACROSS HOW MANY
/// FILES. Confirmed real (single-file case): banking.bluebook's
/// `Account` aggregate declares `policy "ReviewOnFreeze"` INSIDE itself,
/// followed much later in the file by four chapter-level policies — the
/// real `ir.json` puts `ReviewOnFreeze` FIRST regardless. `parse_chapter`
/// combines the two accumulators exactly once, after every file has
/// contributed — see its own final `bluebook.policies = ...` lines.
fn parse_body_into(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    bluebook: &mut ir::Bluebook,
    aggregate_policies: &mut Vec<ir::Policy>,
    chapter_policies: &mut Vec<ir::Policy>,
    chapter_named_givens: &mut Vec<(String, ir::Given)>,
    // EVERY BARE CHAPTER-GIVEN A FILE PARSED SO FAR LEFT PENDING — see
    // `aggregate::PendingChapterGiven`'s own comment; `parse_chapter`
    // resolves every one of these once every file has loaded.
    pending_chapter_givens: &mut Vec<(usize, aggregate::PendingChapterGiven)>,
    // ONE LEVEL DEEPER — a COMMAND's own bare reference to the same
    // not-yet-resolved chapter-given (`command::PendingCommandGiven`'s
    // own comment).
    pending_command_givens: &mut Vec<(usize, usize, command::PendingCommandGiven)>,
) -> ParseResult<()> {
    // THE ROOT of the chapter-wide given pool
    // (`docs/implemented/resolution-rules/chapter-given.md`) belongs to the
    // accumulated chapter, not one physical file. Ruby keeps one
    // `BluebookBuilder` open per chapter name, so later business-concept files
    // may reference a named given declared by an earlier one.
    // (owner aggregate name, its own `Given`) pairs — see `aggregate::
    // try_reference_named_chapter_given`'s own header for why this is
    // keyed by owner too, not a flat `Given` list.
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
            "formerly_known_as" => {
                bluebook.formerly_known_as = Some(super::positional_text(
                    file,
                    line,
                    "formerly_known_as",
                    &gated.args,
                    1,
                )?)
            }
            "core" => bluebook.classification = Some("core".to_string()),
            "supporting" => bluebook.classification = Some("supporting".to_string()),
            "generic" => bluebook.classification = Some("generic".to_string()),
            // ADR 0026, S15 — VARIADIC, same shape `group_by`'s own
            // parsing is: as many positional TEXT arguments as the
            // source gave (`positional_text`, not `positional_symbol` —
            // these are quoted strings, "Query"/"ReadModel", not
            // symbols), accumulating rather than overwriting since
            // nothing here refuses a second `attaches_to` call.
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
                let (built, policies, pending, command_pending) =
                    aggregate::parse_body(file, lines, pos, &agg_name, chapter_named_givens)?;
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
