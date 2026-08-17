//! The `Bluebook` construct — the top of the construct chain
//! (`lib/hecksagain/bluebook/ir/bluebook.rb`), and the driver for
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
//! (`MetaValidator::GRAMMAR_FILES`, nine files sharing one chapter name —
//! the self-hosted language parsing its own grammar) is now real,
//! mirroring `BluebookBuilder.build`'s own accumulating-builder shape
//! (`meta_validator.rb`'s own comment: "`BluebookBuilder.build` keeps
//! one builder open per chapter name across calls ... so loading all
//! nine in order accumulates one domain, not nine"). Concretely: every
//! `Bluebook`-context file's body is parsed into the SAME `ir::Bluebook`
//! accumulator, in file order — `aggregate`/`policy`/`report`/
//! `process_manager` all APPEND across files exactly as they do within
//! one file, while `vision`/`core`/`supporting`/`generic`/
//! `formerly_known_as` (single-value fields) are SET, not reset, by a
//! later file that doesn't mention them — matching
//! `BluebookBuilder#vision`/`#core`/etc.'s own plain `@ivar = value`
//! assignment, never touched by a file that has no such line. The
//! header's own `version:` is read ONLY from the FIRST file — Ruby's own
//! `registry.bluebook_builder(name) { new(name, version: version) }`
//! only calls `new` (and so only reads `version:`) the FIRST time a
//! builder for this chapter name is created; every later
//! `Hecks.bluebook "Bluebook", ...` call fetches the SAME memoized
//! builder and its `version:` kwarg is silently ignored — confirmed real:
//! only `bluebook.bluebook` (loaded first, per `GRAMMAR_FILES`) carries
//! `version: "1"`, the other eight files carry none.
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

use super::{aggregate, policy, process_manager, read_model};
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
        return Err(Diagnostic::new("<none>", 0, "hecks-parse chapter requires at least one file"));
    }

    let mut bluebook: Option<ir::Bluebook> = None;
    let mut aggregate_policies: Vec<ir::Policy> = Vec::new();
    let mut chapter_policies: Vec<ir::Policy> = Vec::new();
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
                // FIRST Bluebook-context file: mints the accumulator and
                // reads `version:` off ITS OWN header — see this module's
                // own header on why only the first file's `version:`
                // counts. Every later Bluebook-context file parses its
                // body into the SAME accumulator instead of minting a
                // fresh one — see `parse_body_into`.
                if bluebook.is_none() {
                    let mut built = ir::Bluebook { name: chapter_name.to_string(), ..Default::default() };
                    built.version = super::file::header_version(&call);
                    bluebook = Some(built);
                }
                let target = bluebook.as_mut().expect("just set above");
                parse_body_into(path, &lines, &mut pos, target, &mut aggregate_policies, &mut chapter_policies)?;
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

    let mut bluebook = bluebook.ok_or_else(|| Diagnostic::new("<none>", 0, format!("no .bluebook file given for chapter '{chapter_name}'")))?;

    // Combined ONCE, after every Bluebook-context file has contributed —
    // matching `BluebookBuilder#build`'s own `@aggregates.flat_map(&:policies)
    // + @policies`, run only at the very end regardless of how many files
    // fed the accumulator.
    bluebook.policies = aggregate_policies;
    bluebook.policies.extend(chapter_policies);

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
                super::hecksagon::apply(path, &lines, &mut pos, &mut bluebook, &mut Vec::new(), true)?;
            } else {
                // A SIBLING hecksagon for a DIFFERENT chapter, physically
                // sharing this file (see this module's own header) —
                // still gated for real, its content simply never reaches
                // the real `bluebook`.
                let mut discarded = ir::Bluebook::default();
                super::hecksagon::apply(path, &lines, &mut pos, &mut discarded, &mut Vec::new(), true)?;
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
pub fn resolve_uses_framework(chapter_name: &str, path: &str, source: &str) -> ParseResult<Vec<String>> {
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
                format!("a .hecksagon file's own top-level blocks must all be 'hecksagon'; got '{}'", call.word),
            ));
        }

        let declared_name = super::file::header_name(&call);
        if declared_name.as_deref() == Some(chapter_name) {
            found = true;
            let mut discarded = ir::Bluebook::default();
            super::hecksagon::apply(path, &lines, &mut pos, &mut discarded, &mut names, false)?;
        } else {
            let mut discarded = ir::Bluebook::default();
            super::hecksagon::apply(path, &lines, &mut pos, &mut discarded, &mut Vec::new(), true)?;
        }
    }

    if !found {
        return Err(Diagnostic::new(path, 0, format!("no 'Hecks.hecksagon \"{chapter_name}\"' block found in {path}")));
    }

    Ok(names)
}

/// Parses a `Hecks.bluebook "Name" do ... end` body INTO an
/// already-existing accumulator — `vision`/`core`/`supporting`/
/// `generic`/`aggregate`/`policy`/`report`/`read_model`. STAGE 4 added
/// `process_manager` (banking.bluebook's own three sagas).
/// `formerly_known_as` is declared but not exercised by any real corpus
/// member yet — still falls through to `not_built_yet`.
///
/// STAGE 6: takes `bluebook`/`aggregate_policies`/`chapter_policies` BY
/// MUTABLE REFERENCE rather than minting and returning fresh ones, so
/// `parse_chapter` can call this once per Bluebook-context FILE while
/// every file appends onto the SAME running totals — the shape
/// `BluebookBuilder`'s own single, registry-memoized builder instance
/// has across the nine `MetaValidator::GRAMMAR_FILES` calls (see this
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
) -> ParseResult<()> {
    // THE ROOT of the chapter-wide given pool
    // (`docs/resolution-rules/chapter-given.md`) — SCOPED TO THIS FILE,
    // not `parse_chapter`'s own cross-file loop, matching Ruby exactly:
    // `Hecks.bluebook "X" do ... end` mints a FRESH `BluebookBuilder`
    // (`lib/hecksagain.rb#bluebook`) — and therefore a fresh
    // `@chapter_named_givens` — on EVERY call, even when several files
    // (the self-hosted meta-domain's own nine) declare the SAME chapter
    // name; sharing never crosses a file boundary either side.
    let mut chapter_named_givens: Vec<ir::Given> = Vec::new();

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Bluebook")? else {
            break;
        };
        let line = gated.line.number;

        match gated.row.word {
            "vision" => bluebook.vision = Some(super::positional_text(file, line, "vision", &gated.args, 1)?),
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
                    bluebook.attaches_to.push(super::positional_text(file, line, "attaches_to", &gated.args, at)?);
                }
            }
            "aggregate" => {
                let agg_name = super::positional_text(file, line, "aggregate", &gated.args, 1)?;
                let (built, policies) = aggregate::parse_body(file, lines, pos, &agg_name, &mut chapter_named_givens)?;
                bluebook.aggregates.push(built);
                aggregate_policies.extend(policies);
            }
            "policy" => {
                let pol_name = super::positional_text(file, line, "policy", &gated.args, 1)?;
                chapter_policies.push(policy::parse_body(file, lines, pos, &pol_name)?);
            }
            "read_model" => {
                let rm_name = super::positional_text(file, line, "read_model", &gated.args, 1)?;
                bluebook.read_models.push(read_model::parse_body(file, lines, pos, &rm_name)?);
            }
            "process_manager" => {
                let pm_name = super::positional_text(file, line, "process_manager", &gated.args, 1)?;
                bluebook.process_managers.push(process_manager::parse_body(file, lines, pos, &pm_name)?);
            }
            _ => return Err(super::not_built_yet("Bluebook", gated.row, file, line, &gated.call.word)),
        }
    }

    Ok(())
}
