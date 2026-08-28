//! `hecks-parse` — the fresh, purpose-built Rust parser for hecks's
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
/// chapter's `ir.json` on stdout. Most real chapters parse for real now
/// (spec/parser_parity_spec.rb's REAL_PARITY_MEMBERS); "not yet
/// implemented" is expected only for a member still on that spec's own
/// PENDING_MEMBERS table, or an unsupported construct inside an
/// otherwise-real chapter (see parse::chapter's own header).
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
    let chapter_name = chapter_name.ok_or_else(|| {
        RunError::Usage("hecks-parse chapter --chapter <Name> <files...>".to_string())
    })?;
    if files.is_empty() {
        return Err(RunError::Usage(
            "hecks-parse chapter --chapter <Name> <files...> — no files given".to_string(),
        ));
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

/// `hecks-parse resolve --chapter <Name> <file.hecksagon>` — `{"domain":
/// "<Name>", "uses_framework": [...]}`. STAGE 8: real, not a stub —
/// `parse::chapter::resolve_uses_framework` walks every top-level
/// `Hecks.hecksagon "..." do ... end` block in the file (fail-closed
/// gated, exactly like `chapter`'s own `.hecksagon` handling), applies
/// only the block whose own declared name matches `--chapter`, and
/// returns every `uses_framework "X"` argument it names, in file order.
///
/// `--chapter` is REQUIRED, a deliberate departure from the plan's own
/// original `hecks-parse resolve <file.hecksagon>` sketch (no chapter
/// argument at all): a single `.hecksagon` file can declare MORE THAN
/// ONE `Hecks.hecksagon` block (banking.hecksagon's own shape — a
/// `"Banking"` block plus sibling `"Governance"`/`"Identity"` blocks,
/// see `parse::chapter`'s own header), so "the domain" isn't something
/// this file can safely infer on its own — the caller (`bin/project_
/// rust`'s opt-in orchestration) already knows the target chapter's own
/// declared name (read off its `.bluebook` file's header, the same way
/// `hecks-parse chapter --chapter <Name> ...` already requires it
/// upfront) and passes it through rather than have this command guess.
fn run_resolve(args: &[String]) -> Result<(), RunError> {
    let mut chapter_name: Option<String> = None;
    let mut path: Option<&String> = None;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--chapter" {
            chapter_name = iter.next().cloned();
        } else {
            path = Some(arg);
        }
    }
    let chapter_name = chapter_name.ok_or_else(|| {
        RunError::Usage("hecks-parse resolve --chapter <Name> <file.hecksagon>".to_string())
    })?;
    let path = path.ok_or_else(|| {
        RunError::Usage("hecks-parse resolve --chapter <Name> <file.hecksagon>".to_string())
    })?;

    let source = fs::read_to_string(path)
        .map_err(|e| RunError::Usage(format!("could not read '{path}': {e}")))?;
    let names = parse::chapter::resolve_uses_framework(&chapter_name, path, &source)?;

    let value = emit::JsonValue::Object(vec![
        ("domain".to_string(), emit::JsonValue::String(chapter_name)),
        (
            "uses_framework".to_string(),
            emit::JsonValue::Array(names.into_iter().map(emit::JsonValue::String).collect()),
        ),
    ]);
    println!("{}", emit::write(&value));
    Ok(())
}

/// `hecks-parse coverage` — prints the `(word, context)` pairs ACTUALLY
/// implemented, as a JSON array of `[word, context]` pairs, for
/// `spec/parser_coverage_spec.rb` to compare against `syntax.bluebook`'s
/// own declared set (minus a shrinking, itemized allowlist).
///
/// Every pair listed here is a word this parser genuinely turns into real
/// `ir::*` fields for some real corpus member's own real usage of it —
/// confirmed by `spec/parser_parity_spec.rb`'s byte-exact comparison
/// against Ruby's own `ir.json`, not just "the word gates cleanly." A
/// word this crate merely GATES but doesn't build real IR for (e.g.
/// `entity`) stays off this list — reporting it here would be exactly
/// the kind of claim this whole plan exists to make impossible.
/// `identified_by`'s bare-field form (ADR 0025's LIVE spelling, `build/
/// identity.rs::resolve_identity_field`) joined the legacy type-form in
/// building real IR, so the pair stays listed on the same terms it
/// always was. Grouped by construct, in the same order
/// `parse::mod::dispatch_stub` maps contexts.
///
/// STAGE 2 built the first block (pizzas.bluebook). STAGE 3 added the
/// entries marked below. STAGE 4 (banking.bluebook — entities, composite
/// identity, process managers, read models with every query option,
/// `provenance`, a nested `policy`, `belongs_to`, `on`'s blockless form —
/// also confirmed by the concurrently-landed `compliance`/`interview`
/// real corpus members, which this stage's own real construction work
/// happened to fully cover too) adds the entries marked STAGE 4.
///
/// STAGE 6 (the self-hosted grammar itself,
/// `MetaValidator::GRAMMAR_FILES`'s discovered files parsed as one `Bluebook`
/// chapter) adds `("list_of", "Type")`/`("one_of", "Type")` below,
/// marked STAGE 6 — NOT new dispatch work (both have built real IR since
/// Stage 2/3, `resolve_type_expression`'s own header: pizzas.bluebook's
/// `list_of(Topping)`, console_settings.bluebook's inline
/// `one_of("good", ...)`), but a pre-existing BOOKKEEPING gap this stage
/// closed while auditing every `(word, context)` pair the self-hosted
/// grammar's own nine files genuinely exercise (every OTHER pair they
/// use — `aggregate`/`command`/`query`/`attribute`/`value_object`/
/// `identified_by`/`reference_to`/`one_of`(ValueObject)/`member`/
/// `invariant`/`given`/`sets`/`emits`/`role`/`goal`/`where`/`order_by`/
/// `include`/`description`/`report`/`vision`/`core` in their various
/// contexts — was ALREADY on this list). Confirmed by tracing every
/// `next_line` dispatch while parsing the nine files for real (a
/// temporary `eprintln!`, removed again once the audit was done) and
/// cross-checking the traced set against this table by hand.
const COVERED_PAIRS: &[(&str, &str)] = &[
    ("bluebook", "File"),
    ("hecksagon", "File"),
    ("vision", "Bluebook"),
    ("core", "Bluebook"),
    ("supporting", "Bluebook"),
    ("generic", "Bluebook"),
    ("aggregate", "Bluebook"),
    ("policy", "Bluebook"),
    ("process_manager", "Bluebook"), // STAGE 4
    ("description", "Aggregate"),
    ("provenance", "Aggregate"), // STAGE 4
    ("identified_by", "Aggregate"),
    ("attribute", "Aggregate"),
    ("value_object", "Aggregate"),
    ("lifecycle", "Aggregate"),
    ("entity", "Aggregate"), // STAGE 4
    ("query", "Aggregate"),
    ("command", "Aggregate"),
    ("policy", "Aggregate"),       // STAGE 4
    ("reference_to", "Aggregate"), // STAGE 3
    ("belongs_to", "Aggregate"),   // STAGE 4
    ("description", "Entity"),     // STAGE 4
    ("identified_by", "Entity"),   // STAGE 4
    ("attribute", "Entity"),       // STAGE 4
    ("command", "Entity"),         // STAGE 4
    ("query", "Entity"),           // STAGE 4
    ("lifecycle", "Entity"),       // STAGE 4
    ("role", "Command"),
    ("goal", "Command"),
    ("reference_to", "Command"),
    ("given", "Command"),
    ("ensures", "Command"), // STAGE 4
    ("sets", "Command"),
    ("emits", "Command"),
    ("attribute", "Command"),
    ("attribute", "ValueObject"),
    ("one_of", "ValueObject"),
    ("invariant", "ValueObject"),
    ("member", "OneOf"),
    ("transition", "Lifecycle"),
    ("description", "Query"), // STAGE 3
    ("attribute", "Query"),
    ("where", "Query"),
    ("order_by", "Query"),
    ("limit", "Query"),     // STAGE 4
    ("authorize", "Query"), // STAGE 4
    ("on", "Policy"),
    ("trigger", "Policy"),
    ("across", "Policy"),                // STAGE 4
    ("correlates_by", "ProcessManager"), // STAGE 4
    ("starts_on", "ProcessManager"),     // STAGE 4
    ("ends_on", "ProcessManager"),       // STAGE 4
    ("state", "ProcessManager"),         // STAGE 4
    ("on", "ProcessManager"),            // STAGE 4
    ("dispatch", "Handler"),             // STAGE 4
    ("port", "Hecksagon"),
    ("operation", "DomainPort"),
    ("reference_to", "PortOperation"),
    ("attribute", "PortOperation"),
    ("emits", "PortOperation"),
    ("read_model", "Bluebook"),    // STAGE 3
    ("description", "ReadModel"),  // STAGE 3
    ("include", "ReadModel"),      // STAGE 3
    ("group_by", "ReadModel"),     // STAGE 3
    ("count", "ReadModel"), // real, this session — banking.bluebook's own DisputedPaymentCount
    ("median", "ReadModel"), // real, this session — banking.bluebook's own DisputedPaymentMedian
    ("reference_to", "ReadModel"), // STAGE 4
    ("where", "ReadModel"), // STAGE 4
    ("order_by", "ReadModel"), // STAGE 4
    ("limit", "ReadModel"), // STAGE 4
    ("list_of", "Type"),    // STAGE 6 (bookkeeping — see this const's own header)
    ("one_of", "Type"),     // STAGE 6 (bookkeeping — see this const's own header)
];

fn run_coverage(_args: &[String]) -> Result<(), RunError> {
    let pairs: Vec<String> = COVERED_PAIRS
        .iter()
        .map(|(word, context)| format!("[\"{word}\", \"{context}\"]"))
        .collect();
    println!("[{}]", pairs.join(", "));
    Ok(())
}
