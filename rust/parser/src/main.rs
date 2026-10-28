//! `hecks-parse`: parses `.bluebook` files into `ir.json` and reports the constructs it covers.
//! Every line passes four gates (shape, word, body, argument); unknown constructs are errors.

mod build;
mod canonical;
mod diag;
mod emit;
mod expr;
// The one `Hecks::Naming` port, compiled from `hecks-codegen`'s source: neither crate depends on
// the other. This crate reads only part of it.
#[allow(dead_code)]
#[path = "../../codegen/src/hecks_naming.rs"]
mod hecks_naming;
mod ir;
// Generated table; not every column is consumed by this binary.
#[allow(dead_code)]
mod keywords;
mod lex;
mod parse;
// Generated table of the sentence form's phrases; not every column is read by this binary.
#[allow(dead_code)]
mod phrases;
mod render_ruby;
mod ruby_value;
mod sentence;

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
        Self::Parse(d)
    }
}

fn run(args: &[String]) -> Result<(), RunError> {
    match args.first().map(String::as_str) {
        Some("bluebook") => run_bluebook(&args[1..]),
        Some("render") => run_render(&args[1..]),
        Some("complete") => run_complete(&args[1..]),
        Some("format") => run_format(&args[1..]),
        Some("examples") => run_examples(&args[1..]),
        Some("resolve") => run_resolve(&args[1..]),
        Some("adapter") => run_adapter(&args[1..]),
        Some("world") => run_world(&args[1..]),
        Some("coverage") => {
            run_coverage();
            Ok(())
        }
        Some(other) => Err(RunError::Usage(format!(
            "unknown subcommand '{other}' — expected 'bluebook', 'resolve', 'adapter', 'world', or 'coverage'"
        ))),
        None => Err(RunError::Usage(
            "hecks-parse <bluebook|resolve|adapter|world|coverage> ...".to_string(),
        )),
    }
}

/// The bluebook a `bluebook` or `render` call names and the files it reads, as `(path, source)`.
fn read_bluebook_args(
    subcommand: &str,
    args: &[String],
) -> Result<(String, Vec<(String, String)>), RunError> {
    let mut declaration_name: Option<String> = None;
    let mut files: Vec<String> = Vec::new();
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--bluebook" {
            declaration_name = iter.next().cloned();
        } else {
            files.push(arg.clone());
        }
    }
    let declaration_name = declaration_name.ok_or_else(|| {
        RunError::Usage(format!(
            "hecks-parse {subcommand} --bluebook <Name> <files...>"
        ))
    })?;
    if files.is_empty() {
        return Err(RunError::Usage(format!(
            "hecks-parse {subcommand} --bluebook <Name> <files...> — no files given"
        )));
    }

    let loaded: Vec<(String, String)> = files
        .iter()
        .map(|path| {
            let source = fs::read_to_string(path)
                .map_err(|e| RunError::Usage(format!("could not read '{path}': {e}")))?;
            Ok((path.clone(), source))
        })
        .collect::<Result<_, RunError>>()?;
    Ok((declaration_name, loaded))
}

/// `hecks-parse bluebook --bluebook <Name> <files...>`: emits the bluebook's `ir.json` on stdout.
fn run_bluebook(args: &[String]) -> Result<(), RunError> {
    let (declaration_name, loaded) = read_bluebook_args("bluebook", args)?;
    let bluebook = parse::declaration::parse_bluebook(&declaration_name, &loaded)?;
    println!("{}", emit::write(&emit::bluebook_json(&bluebook)));
    Ok(())
}

/// `hecks-parse render --bluebook <Name> <files...>`: prints the bluebook as the Ruby-shaped
/// bluebook text that declares the same IR, so a bluebook written as sentences can be loaded by
/// Ruby.
fn run_render(args: &[String]) -> Result<(), RunError> {
    let (declaration_name, loaded) = read_bluebook_args("render", args)?;
    let bluebook = parse::declaration::parse_bluebook(&declaration_name, &loaded)?;
    let first = loaded.first().map_or("<none>", |(path, _)| path.as_str());
    let text = render_ruby::ruby_form(&bluebook)
        .map_err(|why| RunError::Parse(diag::Diagnostic::new(first, 1, why)))?;
    print!("{text}");
    Ok(())
}

/// `hecks-parse examples --bluebook <Name> --examples <file> [--also <file>] <files...>`:
/// prints the `.behaviors` text that runs the examples file against the bluebook. Each `--also`
/// file is booted with it but not parsed, as a hecksagon is.
fn run_examples(args: &[String]) -> Result<(), RunError> {
    let mut examples_path: Option<String> = None;
    let mut also: Vec<String> = Vec::new();
    let mut rest: Vec<String> = Vec::new();
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--examples" => examples_path = iter.next().cloned(),
            "--also" => also.extend(iter.next().cloned()),
            _ => rest.push(arg.clone()),
        }
    }
    let examples_path = examples_path.ok_or_else(|| {
        RunError::Usage(
            "hecks-parse examples --bluebook <Name> --examples <file> <files...>".to_string(),
        )
    })?;
    let (declaration_name, loaded) = read_bluebook_args("examples", &rest)?;
    let source = fs::read_to_string(&examples_path)
        .map_err(|e| RunError::Usage(format!("could not read '{examples_path}': {e}")))?;
    let bluebook = parse::declaration::parse_bluebook(&declaration_name, &loaded)?;
    // The suite boots the bluebook's files and then any `--also` files (the Memory-bound
    // hecksagon that answers the bluebook's asks), each by its absolute path.
    let absolute: Vec<String> = loaded
        .iter()
        .map(|(path, _)| path)
        .chain(also.iter())
        .map(|path| {
            fs::canonicalize(path)
                .map_or_else(|_| path.clone(), |full| full.to_string_lossy().into_owned())
        })
        .collect();
    let text = sentence::examples::compile(&bluebook, &absolute, &examples_path, &source)?;
    print!("{text}");
    Ok(())
}

/// `hecks-parse format --bluebook <Name> <files...>`: prints the bluebook, whichever form its files
/// are written in, as canonical sentences.
fn run_format(args: &[String]) -> Result<(), RunError> {
    let (declaration_name, loaded) = read_bluebook_args("format", args)?;
    let bluebook = parse::declaration::parse_bluebook(&declaration_name, &loaded)?;
    let first = loaded.first().map_or("<none>", |(path, _)| path.as_str());
    let text = sentence::format::sentences(&bluebook)
        .map_err(|why| RunError::Parse(diag::Diagnostic::new(first, 1, why)))?;
    print!("{text}");
    Ok(())
}

/// `hecks-parse complete <file> --line N --col N`: prints, as JSON, the sentences an author may
/// write at that cursor of a file written as sentences. Both numbers are 1-based.
fn run_complete(args: &[String]) -> Result<(), RunError> {
    let usage = || RunError::Usage("hecks-parse complete <file> --line N --col N".to_string());
    let mut path: Option<&String> = None;
    let mut line: Option<usize> = None;
    let mut col: Option<usize> = None;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--line" => line = iter.next().and_then(|value| value.parse().ok()),
            "--col" => col = iter.next().and_then(|value| value.parse().ok()),
            _ => path = Some(arg),
        }
    }
    let (Some(path), Some(line), Some(col)) = (path, line, col) else {
        return Err(usage());
    };
    let source = fs::read_to_string(path)
        .map_err(|e| RunError::Usage(format!("could not read '{path}': {e}")))?;

    let found = sentence::complete::complete(&source, line, col);
    let items: Vec<emit::JsonValue> = found
        .items
        .iter()
        .map(|item| {
            emit::JsonValue::Object(vec![
                (
                    "label".to_string(),
                    emit::JsonValue::str(item.label.clone()),
                ),
                (
                    "insert".to_string(),
                    emit::JsonValue::str(item.insert.clone()),
                ),
                (
                    "snippet".to_string(),
                    emit::JsonValue::str(item.snippet.clone()),
                ),
            ])
        })
        .collect();
    let value = emit::JsonValue::Object(vec![
        ("context".to_string(), emit::JsonValue::str(found.context)),
        ("items".to_string(), emit::JsonValue::Array(items)),
    ]);
    println!("{}", emit::write(&value));
    Ok(())
}

/// `hecks-parse resolve --bluebook <Name> <file.hecksagon>`: prints that bluebook's
/// `attaches` names as JSON, in file order: `gem_bluebooks` for a bluebook the gem carries and
/// `vendored_packages` for `from: :vendor`.
///
/// `--bluebook` is required because one file can hold several `Hecks.hecksagon` blocks.
fn run_resolve(args: &[String]) -> Result<(), RunError> {
    let mut declaration_name: Option<String> = None;
    let mut path: Option<&String> = None;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--bluebook" {
            declaration_name = iter.next().cloned();
        } else {
            path = Some(arg);
        }
    }
    let declaration_name = declaration_name.ok_or_else(|| {
        RunError::Usage("hecks-parse resolve --bluebook <Name> <file.hecksagon>".to_string())
    })?;
    let path = path.ok_or_else(|| {
        RunError::Usage("hecks-parse resolve --bluebook <Name> <file.hecksagon>".to_string())
    })?;

    let source = fs::read_to_string(path)
        .map_err(|e| RunError::Usage(format!("could not read '{path}': {e}")))?;
    let (framework_names, vendored_names) =
        parse::declaration::resolve_hecksagon_dependencies(&declaration_name, path, &source)?;

    let gem_bluebooks = || {
        emit::JsonValue::Array(
            framework_names
                .iter()
                .cloned()
                .map(emit::JsonValue::String)
                .collect(),
        )
    };
    let value = emit::JsonValue::Object(vec![
        ("domain".to_string(), emit::JsonValue::String(declaration_name)),
        ("gem_bluebooks".to_string(), gem_bluebooks()),
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

/// `hecks-parse adapter <file.adapter>...`: prints the declared adapters as a JSON array, in
/// file order then declaration order.
fn run_adapter(args: &[String]) -> Result<(), RunError> {
    if args.is_empty() {
        return Err(RunError::Usage(
            "hecks-parse adapter <file.adapter>...".to_string(),
        ));
    }
    let mut adapters = Vec::new();
    for path in args {
        let source = fs::read_to_string(path)
            .map_err(|e| RunError::Usage(format!("could not read '{path}': {e}")))?;
        adapters.extend(parse::adapter::parse_file(path, &source)?);
    }
    let value = emit::JsonValue::Array(adapters.iter().map(emit::adapter_json).collect());
    println!("{}", emit::write(&value));
    Ok(())
}

/// `hecks-parse world <file.world>...`: prints one world per distinct domain, in order of first
/// appearance across the files, later blocks of a domain merged into the first.
fn run_world(args: &[String]) -> Result<(), RunError> {
    if args.is_empty() {
        return Err(RunError::Usage(
            "hecks-parse world <file.world>...".to_string(),
        ));
    }
    let mut blocks = Vec::new();
    for path in args {
        let source = fs::read_to_string(path)
            .map_err(|e| RunError::Usage(format!("could not read '{path}': {e}")))?;
        blocks.extend(parse::world::parse_file(path, &source)?);
    }
    let worlds = parse::world::merge(blocks);
    let value = emit::JsonValue::Array(worlds.iter().map(emit::world_json).collect());
    println!("{}", emit::write(&value));
    Ok(())
}

/// `(word, context)` pairs this parser builds real IR for, printed by `hecks-parse coverage`.
/// A word that is only gated, never built into IR, must stay off this list.
const COVERED_PAIRS: &[(&str, &str)] = &[
    ("bluebook", "File"),
    ("hecksagon", "File"),
    ("adapter", "File"),
    ("port", "Adapter"),
    ("field", "Adapter"),
    ("secret", "Adapter"),
    ("answers_query", "Adapter"),
    ("runs", "Adapter"),
    ("provides", "Adapter"),
    ("world", "File"),
    ("realm", "World"),
    ("latest", "World"),
    ("default_database", "World"),
    ("default_adapter", "World"),
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
    ("acknowledges", "Aggregate"),
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
    ("idempotent", "Command"),
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
    ("mark", "Lifecycle"),
    ("description", "Query"),
    ("attribute", "Query"),
    ("reference_to", "Query"),
    ("where", "Query"),
    ("order_by", "Query"),
    ("limit", "Query"),
    ("authorize", "Query"),
    ("returns", "Query"),
    ("needs", "Query"),
    ("on", "Policy"),
    ("trigger", "Policy"),
    ("ask", "Policy"),
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
    ("driven_by", "Hecksagon"),
    ("operation", "DomainPort"),
    ("tells", "DomainPort"),
    ("asks", "DomainPort"),
    ("reference_to", "PortOperation"),
    ("attribute", "PortOperation"),
    ("emits", "PortOperation"),
    ("answers", "PortOperation"),
    ("refuses", "PortOperation"),
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

fn run_coverage() {
    let pairs: Vec<String> = COVERED_PAIRS
        .iter()
        .map(|(word, context)| format!("[\"{word}\", \"{context}\"]"))
        .collect();
    println!("[{}]", pairs.join(", "));
}
