//! hecksagain - the Rust runtime.
//!
//!   hecksagain <domain.bluebook> <script.json>
//!
//! Reads an IR and a script of commands, runs them, and prints the result as
//! JSON. Its Ruby counterpart (bin/run) takes the same inputs and prints the
//! same shape, so the two outputs can be diffed directly.
//!
//! This binary contains no knowledge of any particular domain.
//!
//! STANDING GAP: it cannot yet parse a .bluebook file. It should. Both
//! runtimes are meant to read the NATIVE format - a JSON IR handed over from
//! Ruby is a stepping stone, not the architecture, and it exists here only
//! because it made semantic parity provable early.
//!
//! The mistake hecksagain exists to avoid is not "two parsers". It is two
//! parsers AUTHORED TWICE BY HAND, held together by a suite that can only
//! detect drift after the fact. A Rust parser that is a PROJECTION of the Ruby
//! one is a different thing entirely: one author, two artifacts. Rust is a
//! projection, except the interpreter.
//!
//! Note that a .bluebook file is already Ruby, so the parseable subset and the
//! evaluable subset are the same question - see
//! lib/hecksagain/grammar/expression.bluebook.

// THE PARSER CAME OVER FROM HECKS WHOLE AND UNEDITED.
//
// ir.rs, parser.rs, parse_blocks.rs, parser_helpers.rs, pattern_subset.rs. It
// knows far more of the grammar than this runtime uses — policies, fixtures,
// cadences, queries, views, process managers — and that surplus is dead code
// HERE while being load-bearing THERE.
//
// Trimming it to silence the warnings would FORK it, which is the one thing
// this cherry-pick exists to avoid: a parser edited on its way over is a
// parser that has to be maintained twice. So the dead code is allowed by name,
// on exactly these modules and nowhere else. Every other file in this crate
// still builds clean.
//
// ir_json.rs is the one seam we wrote: it renders the typed IR in the shape
// this interpreter reads. When the Rust parser becomes a projection of the
// Ruby one, that is the only file that changes.
// Those modules live in the LIBRARY (src/lib.rs), which is named `storehouse`
// so the adapters cherry-picked from Hecks import it unedited. This binary is
// a thin driver over it.
use storehouse::ports::persistence;
use storehouse::{dispatcher, dump, ir_json, parser};



use dispatcher::Runtime;
use serde_json::{json, Map, Value};
use std::fs;

fn main() {
    let arguments: Vec<String> = std::env::args().collect();

    // `--dump <bluebook>` prints the IR this parser read, so it can be diffed
    // against the IR Ruby's parser read. Agreeing on BEHAVIOUR is good ;
    // agreeing on the IR itself is the stronger claim, because it shows the
    // two parsers understood the same document rather than two documents that
    // happened to run the same.
    if arguments.len() == 3 && arguments[1] == "--dump" {
        println!("{}", serde_json::to_string_pretty(&read_bluebook(&arguments[2])).unwrap());
        return;
    }

    // `--canonical` prints the CANONICAL IR — the parity contract Hecks holds
    // its two implementations to, brought over in dump.rs unedited. Hecks
    // measures its agreement against THIS shape (113/113, zero active drift),
    // so it is the contract worth answering to rather than one invented here.
    //
    // Only half of it is present so far: its Ruby counterpart, canonical_ir.rb,
    // walks Hecks's BluebookModel, which this project does not have yet — so
    // nothing can be diffed against this output until the Ruby model comes over
    // too. Wired now because the Rust half is a clean lift, and because it
    // proves the parsed Domain is rich enough to satisfy the real contract
    // rather than only the subset this interpreter happens to read.
    // `--wiring` reports which adapter the hecksagon bound and where the world
    // points it. A runtime that silently falls back to memory when it cannot
    // read its own wiring is a runtime that lies, so this makes the resolution
    // inspectable rather than something to be inferred from whether a file
    // appeared.
    if arguments.len() == 3 && arguments[1] == "--wiring" {
        // PER AGGREGATE, because that is how persistence binds. Reporting one
        // adapter for the whole domain was not merely incomplete : on a domain
        // binding two different adapters it named one and read as the whole truth.
        //
        // Every aggregate appears, including the ones nobody wired — those report
        // the Memory default, which is the honest answer to "where does this
        // store" and the one a reader most needs when they expected a database.
        let source = fs::read_to_string(&arguments[2]).unwrap_or_else(|error| {
            eprintln!("cannot read {}: {}", arguments[2], error);
            std::process::exit(1);
        });
        for aggregate in parser::parse(&source).aggregates.iter() {
            let persistence = match persistence::resolve_for(&arguments[2], &aggregate.name) {
                Ok(persistence) => persistence,
                // The report's job is to show the wiring as it stands, including
                // that an aggregate has none.
                Err(reason) => {
                    println!("{}: UNBOUND — {}", aggregate.name, reason);
                    continue;
                }
            };
            // WHICH ADAPTER ANSWERS — and only that. Printing the settings
            // alongside read as a claim about storage : a Memory bind showed
            // `database data/mix.db` because the world block is handed over
            // whole and Memory simply ignores it. The port cannot say which
            // settings an adapter reads (that is the adapter's business, and the
            // reason the port stopped resolving a path at all), so it should not
            // imply an answer it does not have.
            println!("{}: {}", aggregate.name, persistence.adapter);
        }
        return;
    }

    if arguments.len() == 3 && arguments[1] == "--canonical" {
        let source = fs::read_to_string(&arguments[2]).unwrap_or_else(|error| {
            eprintln!("cannot read {}: {}", arguments[2], error);
            std::process::exit(1);
        });
        println!(
            "{}",
            serde_json::to_string_pretty(&dump::dump(&parser::parse(&source))).unwrap()
        );
        return;
    }

    if arguments.len() < 3 {
        eprintln!("usage: hecksagain <domain.bluebook> <script.json>");
        eprintln!("       hecksagain --dump <bluebook>");
        std::process::exit(2);
    }

    let ir = read_bluebook(&arguments[1]);
    let script = read_json(&arguments[2]);

    let mut runtime = Runtime::new(ir);

    // CALL THE ADAPTER THE HECKSAGON BOUND. Without this the runtime keeps its
    // state in a HashMap and only APPEARS to persist — the domain would look
    // entirely correct while nothing was ever written.
    // THIS IS THE COMPOSITION ROOT — the one place the port and a concrete
    // adapter may be named together. The library knows only
    // PersistenceAdapter ; storehouse-sqlite is linked here and nowhere else.
    // PERSISTENCE BINDS PER AGGREGATE, so the bind is resolved INSIDE this loop.
    // It used to be resolved once for the whole domain and the first
    // `persisted_by` in the hecksagon handed to every aggregate — so a bluebook
    // wiring Pizza to Sqlite beside Cart to Memory bound EVERYTHING to whichever
    // the parser saw first, silently, with a domain that looked entirely correct.
    //
    // And an aggregate that declares NOTHING gets Memory rather than an error :
    // wiring is override, not substrate. Both behaviours are the projection of
    // lib/hecksagain/ports/persistence/persistence.rb, which holds the semantics.
    for (name, aggregate) in runtime.aggregates() {
        let persistence = match persistence::resolve_for(&arguments[1], &name) {
            Ok(persistence) => persistence,
            Err(reason) => {
                eprintln!("{reason}");
                std::process::exit(1);
            }
        };

        // EACH ADAPTER READS ITS OWN FIELD. The port carries the world block
        // verbatim ; what `database` or `dir` means is the adapter's business,
        // and Memory reads neither, which is why it needs no world block at all.
        let stored_at = |field: &str| -> String {
            match persistence.path(&arguments[1], field) {
                Some(location) => location.to_string_lossy().to_string(),
                None => {
                    eprintln!(
                        "{} binds {}, which stores somewhere, but its world declares no {:?}.",
                        name, persistence.adapter, field
                    );
                    std::process::exit(1);
                }
            }
        };

        // A BIND THAT DOES NOT RESOLVE IS AN ERROR, not a silent fallback. This
        // was `if adapter == "Sqlite"` with no else, so a domain bound to anything
        // else kept its state in a HashMap and looked entirely correct while
        // nothing was written. A store nobody can find is the failure a
        // persistence port exists to make impossible.
        match persistence.adapter.as_str() {
            "Heki" => {
                let path = stored_at("dir");
                let identified_by = aggregate
                    .get("identified_by")
                    .and_then(Value::as_str)
                    .map(str::to_string);

                match storehouse::adapters::driven::heki::HekiRepository::new(
                    &name,
                    &path,
                    identified_by,
                ) {
                    Ok(adapter) => runtime.attach(&name, Box::new(adapter)),
                    Err(error) => {
                        eprintln!("cannot bind Heki at {} for {}: {}", path, name, error);
                        std::process::exit(1);
                    }
                }
            }
            "Memory" => {
                // The runtime's own in-process store IS the memory adapter, and
                // it is what an aggregate gets when nobody wired it.
            }
            "Sqlite" => {
                let path = stored_at("database");

                // The columns ARE the IR: one per declared attribute, its SQL type
                // from storehouse_sqlite::sql_type, which mirrors Ruby's migration
                // generator verbatim. Nothing here chooses a type.
                let columns: Vec<(String, String)> = aggregate
                    .get("attributes")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default()
                    .iter()
                    .filter_map(|attribute| {
                        let column = attribute.get("name").and_then(Value::as_str)?;
                        let declared = attribute.get("type").and_then(Value::as_str).unwrap_or("String");
                        let is_list = attribute.get("list").and_then(Value::as_bool).unwrap_or(false);
                        let sql = if is_list { "TEXT" } else { storehouse_sqlite::sql_type(declared) };
                        Some((column.to_string(), sql.to_string()))
                    })
                    .collect();

                let identified_by = aggregate
                    .get("identified_by")
                    .and_then(Value::as_str)
                    .map(str::to_string);

                match storehouse_sqlite::SqliteRepository::new(&name, &path, identified_by, columns) {
                    Ok(adapter) => runtime.attach(&name, Box::new(adapter)),
                    Err(error) => {
                        eprintln!("cannot bind Sqlite at {} for {}: {}", path, name, error);
                        std::process::exit(1);
                    }
                }
            }
            other => {
                eprintln!(
                    "cannot bind {}: this runtime links Sqlite, Heki and Memory. \
                     An unbound adapter would keep state in a HashMap and look \
                     entirely correct while nothing was written.",
                    other
                );
                std::process::exit(1);
            }
        }
    }
    let mut refusals: Vec<Value> = Vec::new();

    let steps = script
        .get("steps")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    for step in steps {
        let verb = step.get("verb").and_then(Value::as_str).unwrap_or_default();
        let args = step
            .get("args")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();

        // A refusal is a RESULT, not a crash - the parity harness compares
        // refusals as carefully as it compares successes, because a runtime
        // that accepts what the other refuses is the failure worth catching.
        if let Err(message) = runtime.dispatch(verb, &args) {
            refusals.push(json!({ "verb": verb, "error": message }));
        }
    }

    let mut instances = Map::new();
    for (key, state) in runtime.instances() {
        instances.insert(key.clone(), Value::Object(state.clone()));
    }

    let output = json!({
        "instances": Value::Object(instances),
        "events": runtime.events,
        "refusals": refusals,
        // REACTIONS ARE IN THE CONTRACT. Four policies were declared, ran
        // nowhere, and parity stayed green BECAUSE both runtimes discarded
        // them equally — stage one cannot tell "both understood it" from
        // "both threw it away". A reaction the harness does not compare is a
        // reaction that can silently stop happening again.
        "reactions": runtime.reactions,
        // AND SO ARE SAGAS, one construct later : Settlement parsed, both
        // parsers agreed byte-for-byte, and it ran nowhere. Every born /
        // advanced / refused / ended step is compared.
        "sagas": runtime.sagas,
    });

    println!("{}", serde_json::to_string_pretty(&output).unwrap());
}

/// A .bluebook is PARSED. There is no other way in.
///
/// This runtime once accepted a pre-parsed JSON IR as well. That path is gone
/// on purpose: while it existed, Rust could appear to work without its parser
/// being exercised at all, and an unexercised parser is one that quietly rots
/// while the harness reports success. Reading the native format is not a
/// feature of this runtime, it is the only thing it does.
fn read_bluebook(path: &str) -> Value {
    if !path.ends_with(".bluebook") {
        eprintln!("{} is not a .bluebook — this runtime parses the native format", path);
        std::process::exit(2);
    }

    let source = fs::read_to_string(path).unwrap_or_else(|error| {
        eprintln!("cannot read {}: {}", path, error);
        std::process::exit(1);
    });

    // The parser came over from Hecks whole. It is infallible by design — an
    // unreadable construct is recorded in the IR (unknown_keywords) rather
    // than thrown, so a domain is never half-parsed behind an early return.
    ir_json::domain_to_value(&parser::parse(&source))
}

fn read_json(path: &str) -> Value {
    let text = fs::read_to_string(path).unwrap_or_else(|error| {
        eprintln!("cannot read {}: {}", path, error);
        std::process::exit(1);
    });

    serde_json::from_str(&text).unwrap_or_else(|error| {
        eprintln!("cannot parse {}: {}", path, error);
        std::process::exit(1);
    })
}
