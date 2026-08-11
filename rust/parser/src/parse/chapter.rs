//! The `Bluebook` construct — the top of the construct chain
//! (`lib/hecksagain/bluebook/ir/bluebook.rb`), and the driver for
//! `hecks-parse chapter --chapter <Name> <files...>`.
//!
//! Stage 1: parses the header (File context) and walks the WHOLE chapter
//! body for real (every nested line, at every depth, through the same
//! four gates — see parse/mod.rs's `walk_body`). Never reaches IR
//! construction: `build/*.rs`/`ir.rs`/`emit.rs` are all Stage-1 stubs, so
//! even a chapter whose every line gates cleanly ends in
//! `not_implemented` rather than a fabricated success.

use crate::diag::{Diagnostic, ParseResult};
use crate::lex;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Bluebook.{word}"))
}

/// Parses one chapter across one or more source files, in order — real
/// multi-file merging (`MetaValidator::GRAMMAR_FILES`, nine files sharing
/// one chapter name) is Stage 2+ work; Stage 1 processes each file's own
/// header + body in sequence and stops at the FIRST diagnostic, whichever
/// file it comes from. That's "first error aborts" applied across files,
/// not just within one.
pub fn parse_chapter(chapter_name: &str, files: &[(String, String)]) -> ParseResult<()> {
    if files.is_empty() {
        return Err(Diagnostic::new("<none>", 0, "hecks-parse chapter requires at least one file"));
    }

    for (path, source) in files {
        parse_one_file(chapter_name, path, source)?;
    }

    Ok(())
}

fn parse_one_file(chapter_name: &str, path: &str, source: &str) -> ParseResult<()> {
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

    if row.inner.is_empty() {
        return Err(not_implemented(path, header_line, &call.word));
    }
    if row.inner != "Bluebook" {
        return Err(Diagnostic::new(
            path,
            header_line,
            format!("hecks-parse chapter reads .bluebook files (word 'bluebook'); got '{}' (inner context '{}')", call.word, row.inner),
        ));
    }

    super::walk_body(path, &lines, &mut pos, "Bluebook")?;

    // The entire body gated with nothing left unbuilt — still not
    // implemented at Stage 1 regardless (no IR construction, no emit).
    Err(not_implemented(path, header_line, "emit (ir.rs/emit.rs are Stage 1 stubs)"))
}
