//! The `Bluebook` construct — the top of the construct chain
//! (`lib/hecksagain/bluebook/ir/bluebook.rb`), and the driver for
//! `hecks-parse chapter --chapter <Name> <files...>`.
//!
//! Parses each `.bluebook` file's header + body into one `ir::Bluebook`,
//! then applies any `.hecksagon` file(s) given onto the ALREADY-BUILT
//! result (`parse::hecksagon::apply`) — mirroring `bin/project_rust`'s
//! own real load order: the domain's `.bluebook` loads and registers
//! every aggregate FIRST, its `.hecksagon` loads SECOND and mutates
//! those already-registered aggregates (attaching ports). A chapter
//! split across several `.bluebook` files (`MetaValidator::GRAMMAR_FILES`,
//! nine files sharing one chapter name — Stage 6 territory, the
//! self-hosted language parsing its own grammar) is not exercised by
//! pizzas.bluebook (one file) and is refused outright here rather than
//! silently merged wrong.
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
                if bluebook.is_some() {
                    return Err(Diagnostic::not_yet_implemented(
                        path,
                        header_line,
                        "a chapter split across several .bluebook files",
                    ));
                }
                let mut built = parse_body(path, &lines, &mut pos, chapter_name)?;
                // `Hecks.bluebook "Banking", version: "v1" do` — the
                // header's own OPTIONAL `version:` (`super::file::
                // header_version`'s own comment) — read from the HEADER
                // call, not `Bluebook`-context body words, since it's
                // `bluebook`'s own File-context Argument row, not a
                // nested one.
                built.version = super::file::header_version(&call);
                bluebook = Some(built);
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
                super::hecksagon::apply(path, &lines, &mut pos, &mut bluebook)?;
            } else {
                // A SIBLING hecksagon for a DIFFERENT chapter, physically
                // sharing this file (see this module's own header) —
                // still gated for real, its content simply never reaches
                // the real `bluebook`.
                let mut discarded = ir::Bluebook::default();
                super::hecksagon::apply(path, &lines, &mut pos, &mut discarded)?;
            }
        }
    }

    Ok(bluebook)
}

/// Parses a `Hecks.bluebook "Name" do ... end` body — `vision`/
/// `core`/`supporting`/`generic`/`aggregate`/`policy`/`report`/
/// `read_model`. STAGE 4 adds `process_manager` (banking.bluebook's own
/// three sagas). `formerly_known_as` is declared but not exercised by any
/// real corpus member yet — still falls through to `not_built_yet`.
///
/// POLICY BUBBLING ORDER: `BluebookBuilder#build`'s own `policies =
/// @aggregates.flat_map(&:policies) + @policies` — every AGGREGATE's own
/// nested policies, in aggregate declaration order, THEN every
/// CHAPTER-level policy, in ITS OWN declaration order — regardless of how
/// the two kinds interleave in the source text. Confirmed real:
/// banking.bluebook's `Account` aggregate declares `policy
/// "ReviewOnFreeze"` INSIDE itself, followed much later in the file by
/// four chapter-level policies — the real `ir.json` puts
/// `ReviewOnFreeze` FIRST regardless. Two separate accumulators, combined
/// only at the end, are what makes that order come out right no matter
/// where each was written.
fn parse_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str) -> ParseResult<ir::Bluebook> {
    let mut bluebook = ir::Bluebook { name: name.to_string(), ..Default::default() };
    let mut aggregate_policies: Vec<ir::Policy> = Vec::new();
    let mut chapter_policies: Vec<ir::Policy> = Vec::new();

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
            "aggregate" => {
                let agg_name = super::positional_text(file, line, "aggregate", &gated.args, 1)?;
                let (built, policies) = aggregate::parse_body(file, lines, pos, &agg_name)?;
                bluebook.aggregates.push(built);
                aggregate_policies.extend(policies);
            }
            "policy" => {
                let pol_name = super::positional_text(file, line, "policy", &gated.args, 1)?;
                chapter_policies.push(policy::parse_body(file, lines, pos, &pol_name)?);
            }
            "report" => {
                let rm_name = super::positional_text(file, line, "report", &gated.args, 1)?;
                bluebook.read_models.push(read_model::parse_body(file, lines, pos, &rm_name)?);
            }
            "process_manager" => {
                let pm_name = super::positional_text(file, line, "process_manager", &gated.args, 1)?;
                bluebook.process_managers.push(process_manager::parse_body(file, lines, pos, &pm_name)?);
            }
            _ => return Err(super::not_built_yet("Bluebook", gated.row, file, line, &gated.call.word)),
        }
    }

    bluebook.policies = aggregate_policies;
    bluebook.policies.extend(chapter_policies);
    Ok(bluebook)
}
