//! `hecks-parse` — the fresh, purpose-built Rust parser for hecksagain's
//! own `.bluebook` DSL (see `/Users/christopheryoung/.claude/plans/sequential-petting-whale.md`
//! for the full 8-stage plan this crate is Stage 1 of).
//!
//! STAGE 1: crate skeleton, lexer, generated keyword table, and all four
//! parsing gates wired — with every per-construct handler
//! (`parse::aggregate`, `parse::entity`, ...) stubbed to a clear
//! `not_yet_implemented` diagnostic. The differential harness
//! (`spec/parser_parity_spec.rb`, `spec/parser_coverage_spec.rb`) exists
//! and runs GREEN, with an itemized pending list, before this parser
//! implements anything real — that ordering is the plan's actual
//! methodological difference from two previous, failed hand-written
//! Rust bluebook parsers (see the plan's own framing).
//!
//! THE FOUR GATES every line goes through (see parse/mod.rs and lex.rs
//! for where each actually lives):
//!   1. shape     — a line must be one of a small fixed set of forms;
//!                  bare Ruby expressions/`if`/local assignment are hard
//!                  errors (lex.rs::classify).
//!   2. word      — the leading identifier must hit a row in the
//!                  GENERATED `keywords.rs::KEYWORDS` table for the
//!                  current context (parse::word_gate).
//!   3. body      — `none`/`keywords`/`source`/`rows` must match what
//!                  actually follows (parse::body_gate).
//!   4. argument  — positional/named count and lexical kind must match
//!                  the declared `keywords.rs::ARGUMENTS` row(s)
//!                  (parse::argument_gate).
//!
//! **NO LENIENT/BEST-EFFORT MODE, EVER.** An unrecognized construct is
//! always a hard error, never silently skipped — see diag.rs's own
//! header for why this is the single most important invariant here.

mod build;
mod canonical;
mod diag;
mod emit;
mod ir;
mod keywords;
mod lex;
mod parse;
mod ruby_value;

use std::fs;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(RunError::Usage(message)) => {
            eprintln!("usage: {message}");
            ExitCode::from(2)
        }
        Err(RunError::Parse(diagnostic)) => {
            eprintln!("{diagnostic}");
            ExitCode::from(1)
        }
    }
}

enum RunError {
    Usage(String),
    Parse(diag::Diagnostic),
}

impl From<diag::Diagnostic> for RunError {
    fn from(d: diag::Diagnostic) -> Self {
        RunError::Parse(d)
    }
}

fn run(args: &[String]) -> Result<(), RunError> {
    match args.first().map(String::as_str) {
        Some("chapter") => run_chapter(&args[1..]),
        Some("resolve") => run_resolve(&args[1..]),
        Some("coverage") => run_coverage(&args[1..]),
        Some(other) => Err(RunError::Usage(format!(
            "unknown subcommand '{other}' — expected 'chapter', 'resolve', or 'coverage'"
        ))),
        None => Err(RunError::Usage(
            "hecks-parse <chapter|resolve|coverage> ...".to_string(),
        )),
    }
}

/// `hecks-parse chapter --chapter <Name> <files...>` — emits that
/// chapter's `ir.json` on stdout. Stage 1 legitimately fails with
/// "not yet implemented" for every real chapter; that's expected (see
/// parse::chapter's own header).
fn run_chapter(args: &[String]) -> Result<(), RunError> {
    let mut chapter_name: Option<String> = None;
    let mut files: Vec<String> = Vec::new();
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--chapter" {
            chapter_name = iter.next().cloned();
        } else {
            files.push(arg.clone());
        }
    }
    let chapter_name = chapter_name
        .ok_or_else(|| RunError::Usage("hecks-parse chapter --chapter <Name> <files...>".to_string()))?;
    if files.is_empty() {
        return Err(RunError::Usage("hecks-parse chapter --chapter <Name> <files...> — no files given".to_string()));
    }

    let loaded: Vec<(String, String)> = files
        .iter()
        .map(|path| {
            let source = fs::read_to_string(path)
                .map_err(|e| RunError::Usage(format!("could not read '{path}': {e}")))?;
            Ok((path.clone(), source))
        })
        .collect::<Result<_, RunError>>()?;

    let bluebook = parse::chapter::parse_chapter(&chapter_name, &loaded)?;
    println!("{}", emit::write(&emit::bluebook_json(&bluebook)));
    Ok(())
}

/// `hecks-parse resolve <file.hecksagon>` — `{"domain":...,
/// "uses_framework":[...]}`. Stage 1: reads the header for real (File
/// context, word `hecksagon`), then falls into the same
/// `not_yet_implemented` honesty as `chapter` — nothing here builds a
/// resolved framework-member list yet.
fn run_resolve(args: &[String]) -> Result<(), RunError> {
    let path = args
        .first()
        .ok_or_else(|| RunError::Usage("hecks-parse resolve <file.hecksagon>".to_string()))?;
    let source = fs::read_to_string(path).map_err(|e| RunError::Usage(format!("could not read '{path}': {e}")))?;

    let lines = lex::lines(&source);
    let mut pos = 0usize;
    let (row, call, header_line) = parse::file::parse_header(path, &lines, &mut pos)?;

    if call.word != "hecksagon" {
        return Err(diag::Diagnostic::new(
            path,
            header_line,
            format!("hecks-parse resolve reads .hecksagon files (word 'hecksagon'); got '{}'", call.word),
        )
        .into());
    }
    if row.inner != "Hecksagon" {
        return Err(diag::Diagnostic::new(path, header_line, format!("'{}' opened '{}', not Hecksagon", call.word, row.inner)).into());
    }

    // Real, same as `chapter`: the WHOLE body gates for real (every
    // nested `port`/`operation`/... line, at any depth) before this
    // admits nothing is built yet.
    parse::walk_body(path, &lines, &mut pos, "Hecksagon")?;

    Err(parse::hecksagon::not_implemented(path, header_line, "resolve (build/*.rs and ir.rs are Stage 1 stubs)").into())
}

/// `hecks-parse coverage` — prints the `(word, context)` pairs ACTUALLY
/// implemented, as a JSON array of `[word, context]` pairs, for
/// `spec/parser_coverage_spec.rb` to compare against `syntax.bluebook`'s
/// own declared set (minus a shrinking, itemized allowlist).
///
/// STAGE 2: every pair listed here is a word this parser genuinely turns
/// into real `ir::*` fields for pizzas.bluebook's own real usage of it —
/// confirmed by `spec/parser_parity_spec.rb`'s byte-exact comparison
/// against Ruby's own `ir.json` for `Pizzas`, not just "the word gates
/// cleanly." A word this crate merely GATES but doesn't build real IR
/// for (e.g. `identified_by`'s bare-field form, `entity`, `report`) stays
/// off this list — reporting it here would be exactly the kind of claim
/// this whole plan exists to make impossible. Grouped by construct, in
/// the same order `parse::mod::dispatch_stub` maps contexts.
const COVERED_PAIRS: &[(&str, &str)] = &[
    ("bluebook", "File"),
    ("hecksagon", "File"),
    ("vision", "Bluebook"),
    ("core", "Bluebook"),
    ("supporting", "Bluebook"),
    ("generic", "Bluebook"),
    ("aggregate", "Bluebook"),
    ("policy", "Bluebook"),
    ("description", "Aggregate"),
    ("identified_by", "Aggregate"),
    ("attribute", "Aggregate"),
    ("value_object", "Aggregate"),
    ("lifecycle", "Aggregate"),
    ("query", "Aggregate"),
    ("command", "Aggregate"),
    ("role", "Command"),
    ("goal", "Command"),
    ("reference_to", "Command"),
    ("given", "Command"),
    ("sets", "Command"),
    ("emits", "Command"),
    ("attribute", "Command"),
    ("attribute", "ValueObject"),
    ("one_of", "ValueObject"),
    ("invariant", "ValueObject"),
    ("member", "OneOf"),
    ("transition", "Lifecycle"),
    ("attribute", "Query"),
    ("where", "Query"),
    ("order_by", "Query"),
    ("on", "Policy"),
    ("trigger", "Policy"),
    ("port", "Hecksagon"),
    ("operation", "DomainPort"),
    ("reference_to", "PortOperation"),
    ("attribute", "PortOperation"),
    ("emits", "PortOperation"),
];

fn run_coverage(_args: &[String]) -> Result<(), RunError> {
    let pairs: Vec<String> = COVERED_PAIRS.iter().map(|(word, context)| format!("[\"{word}\", \"{context}\"]")).collect();
    println!("[{}]", pairs.join(", "));
    Ok(())
}
