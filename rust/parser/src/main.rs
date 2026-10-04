//! `hecks-parse`: parses `.bluebook` files into `ir.json` and reports the constructs it covers.
//! Every line passes four gates (shape, word, body, argument); unknown constructs are errors.

mod build;
mod canonical;
mod diag;
mod emit;
mod expr;
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

/// `hecks-parse chapter --chapter <Name> <files...>`: emits the chapter's `ir.json` on stdout.
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

/// `hecks-parse resolve --chapter <Name> <file.hecksagon>`: prints that chapter's
/// `attaches` names as JSON, in file order: `gem_chapters` for a chapter the gem carries and
/// `vendored_packages` for `from: :vendor`.
///
/// `--chapter` is required because one file can hold several `Hecks.hecksagon` blocks.
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
    let (framework_names, vendored_names) =
        parse::chapter::resolve_hecksagon_dependencies(&chapter_name, path, &source)?;

    let value = emit::JsonValue::Object(vec![
        ("domain".to_string(), emit::JsonValue::String(chapter_name)),
        (
            "gem_chapters".to_string(),
            emit::JsonValue::Array(
                framework_names
                    .into_iter()
                    .map(emit::JsonValue::String)
                    .collect(),
            ),
        ),
        (
            "vendored_packages".to_string(),
            emit::JsonValue::Array(
                vendored_names
                    .into_iter()
                    .map(emit::JsonValue::String)
                    .collect(),
            ),
        ),
    ]);
    println!("{}", emit::write(&value));
    Ok(())
}

/// `(word, context)` pairs this parser builds real IR for, printed by `hecks-parse coverage`.
/// A word that is only gated, never built into IR, must stay off this list.
const COVERED_PAIRS: &[(&str, &str)] = &[
    ("bluebook", "File"),
    ("hecksagon", "File"),
    ("vision", "Bluebook"),
    ("core", "Bluebook"),
    ("supporting", "Bluebook"),
    ("generic", "Bluebook"),
    ("aggregate", "Bluebook"),
    ("policy", "Bluebook"),
    ("process_manager", "Bluebook"),
    ("provides", "Bluebook"),
    ("namespace", "Bluebook"),
    ("description", "Aggregate"),
    ("provenance", "Aggregate"),
    ("identified_by", "Aggregate"),
    ("attribute", "Aggregate"),
    ("value_object", "Aggregate"),
    ("lifecycle", "Aggregate"),
    ("entity", "Aggregate"),
    ("query", "Aggregate"),
    ("command", "Aggregate"),
    ("policy", "Aggregate"),
    ("reference_to", "Aggregate"),
    ("belongs_to", "Aggregate"),
    ("description", "Entity"),
    ("identified_by", "Entity"),
    ("attribute", "Entity"),
    ("command", "Entity"),
    ("query", "Entity"),
    ("lifecycle", "Entity"),
    ("role", "Command"),
    ("goal", "Command"),
    ("reference_to", "Command"),
    ("given", "Command"),
    ("ensures", "Command"),
    ("needs", "Command"),
    ("sets", "Command"),
    ("corrects", "Command"),
    ("delegates_to", "Command"),
    ("given", "Aggregate"),
    ("given", "Entity"),
    ("invariant", "Aggregate"),
    ("invariant", "Entity"),
    ("projects", "Aggregate"),
    ("member", "ValueObject"),
    ("compensates", "Dispatch"),
    ("emits", "Command"),
    ("attribute", "Command"),
    ("attribute", "ValueObject"),
    ("one_of", "ValueObject"),
    ("invariant", "ValueObject"),
    ("member", "OneOf"),
    ("transition", "Lifecycle"),
    ("description", "Query"),
    ("attribute", "Query"),
    ("where", "Query"),
    ("order_by", "Query"),
    ("limit", "Query"),
    ("authorize", "Query"),
    ("returns", "Query"),
    ("on", "Policy"),
    ("trigger", "Policy"),
    ("across", "Policy"),
    ("where", "Policy"),
    ("for_each", "Policy"),
    ("correlates_by", "ProcessManager"),
    ("starts_on", "ProcessManager"),
    ("ends_on", "ProcessManager"),
    ("transition", "ProcessManager"),
    ("dispatch", "Handler"),
    ("port", "Hecksagon"),
    ("translates", "Hecksagon"),
    ("bounded", "Hecksagon"),
    ("attaches", "Hecksagon"),
    ("operation", "DomainPort"),
    ("reference_to", "PortOperation"),
    ("attribute", "PortOperation"),
    ("emits", "PortOperation"),
    ("read_model", "Bluebook"),
    ("description", "ReadModel"),
    ("include", "ReadModel"),
    ("group_by", "ReadModel"),
    ("count", "ReadModel"),
    ("median", "ReadModel"),
    ("sum", "ReadModel"),
    ("avg", "ReadModel"),
    ("min", "ReadModel"),
    ("max", "ReadModel"),
    ("percentile", "ReadModel"),
    ("any", "ReadModel"),
    ("all", "ReadModel"),
    ("reference_to", "ReadModel"),
    ("where", "ReadModel"),
    ("order_by", "ReadModel"),
    ("limit", "ReadModel"),
    ("list_of", "Type"),
    ("one_of", "Type"),
];

fn run_coverage(_args: &[String]) -> Result<(), RunError> {
    let pairs: Vec<String> = COVERED_PAIRS
        .iter()
        .map(|(word, context)| format!("[\"{word}\", \"{context}\"]"))
        .collect();
    println!("[{}]", pairs.join(", "));
    Ok(())
}
