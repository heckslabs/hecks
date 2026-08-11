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

use super::{aggregate, policy, read_model};
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
        let lines = lex::lines(source);
        let mut pos = 0usize;
        let (row, call, header_line) = super::file::parse_header(path, &lines, &mut pos)?;

        if let Some(declared_name) = super::file::header_name(&call) {
            if declared_name != chapter_name {
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
                bluebook = Some(parse_body(path, &lines, &mut pos, chapter_name)?);
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
        let lines = lex::lines(source);
        let mut pos = 0usize;
        let (_row, _call, _header_line) = super::file::parse_header(path, &lines, &mut pos)?;
        super::hecksagon::apply(path, &lines, &mut pos, &mut bluebook)?;
    }

    Ok(bluebook)
}

/// Parses a `Hecks.bluebook "Name" do ... end` body — `vision`/
/// `core`/`supporting`/`generic`/`aggregate`/`policy`, the words
/// pizzas.bluebook actually uses at chapter scope, plus `report`/
/// `read_model` (STAGE 3 — console_settings.bluebook's own `Styles`/
/// `Curated`). `formerly_known_as` and `process_manager` are declared but
/// not exercised by any of the three framework bluebooks — still fall
/// through to `not_built_yet`.
fn parse_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str) -> ParseResult<ir::Bluebook> {
    let mut bluebook = ir::Bluebook { name: name.to_string(), ..Default::default() };

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Bluebook")? else {
            return Ok(bluebook);
        };
        let line = gated.line.number;

        match gated.row.word {
            "vision" => bluebook.vision = Some(super::positional_text(file, line, "vision", &gated.args, 1)?),
            "core" => bluebook.classification = Some("core".to_string()),
            "supporting" => bluebook.classification = Some("supporting".to_string()),
            "generic" => bluebook.classification = Some("generic".to_string()),
            "aggregate" => {
                let agg_name = super::positional_text(file, line, "aggregate", &gated.args, 1)?;
                bluebook.aggregates.push(aggregate::parse_body(file, lines, pos, &agg_name)?);
            }
            "policy" => {
                let pol_name = super::positional_text(file, line, "policy", &gated.args, 1)?;
                bluebook.policies.push(policy::parse_body(file, lines, pos, &pol_name)?);
            }
            "report" => {
                let rm_name = super::positional_text(file, line, "report", &gated.args, 1)?;
                bluebook.read_models.push(read_model::parse_body(file, lines, pos, &rm_name)?);
            }
            _ => return Err(super::not_built_yet("Bluebook", gated.row, file, line, &gated.call.word)),
        }
    }
}
