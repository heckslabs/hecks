#[cfg(feature = "parser")]
use storehouse::ports::persistence;
use storehouse::dispatcher;
#[cfg(feature = "parser")]
use storehouse::{ir_json, parser};

use dispatcher::Runtime;
use serde_json::{json, Map, Value};
use std::fs;

fn main() {
    let arguments: Vec<String> = std::env::args().collect();

    // `--dump`/`--dump-shape`/`--wiring` all read `bluebook::parser`
    // directly — debug/dev tooling, not needed by a binary that only ever
    // boots domains already compiled in. `--dump-translation` is NOT gated
    // here: it reads through `translation::parser`, a separate, always-on
    // parser for a different file format (see `parser`'s own feature doc,
    // rust/Cargo.toml).
    #[cfg(feature = "parser")]
    if arguments.len() == 3 && arguments[1] == "--dump" {
        println!(
            "{}",
            serde_json::to_string_pretty(&read_bluebook(&arguments[2])).unwrap()
        );
        return;
    }

    #[cfg(feature = "parser")]
    if arguments.len() == 3 && arguments[1] == "--dump-shape" {
        let source = fs::read_to_string(&arguments[2]).unwrap_or_else(|error| {
            eprintln!("cannot read {}: {}", arguments[2], error);
            std::process::exit(1);
        });
        println!(
            "{}",
            serde_json::to_string_pretty(&storehouse::runtime::storage_shape::project(
                &parser::parse(&source)
            ))
            .unwrap()
        );
        return;
    }

    if arguments.len() == 3 && arguments[1] == "--dump-translation" {
        println!(
            "{}",
            serde_json::to_string_pretty(&read_translations(&arguments[2])).unwrap()
        );
        return;
    }

    #[cfg(feature = "parser")]
    if arguments.len() == 3 && arguments[1] == "--wiring" {
        let source = fs::read_to_string(&arguments[2]).unwrap_or_else(|error| {
            eprintln!("cannot read {}: {}", arguments[2], error);
            std::process::exit(1);
        });
        for aggregate in parser::parse(&source).aggregates.iter() {
            let persistence = match persistence::resolve_for(&arguments[2], &aggregate.name) {
                Ok(persistence) => persistence,
                Err(reason) => {
                    println!("{}: UNBOUND — {}", aggregate.name, reason);
                    continue;
                }
            };
            println!("{}: {}", aggregate.name, persistence.adapter);
        }
        return;
    }

    if arguments.len() < 3 {
        eprintln!("usage: hecksagain <domain.bluebook> <script.json>");
        eprintln!("       hecksagain --dump <bluebook>");
        eprintln!("       hecksagain --dump-translation <translations dir | edge.bluebook>");
        std::process::exit(2);
    }

    let script = read_json(&arguments[2]);
    storehouse_sqlite::register();
    storehouse_postgres::register();
    let mut runtime = Runtime::boot(&arguments[1]).unwrap_or_else(|reason| {
        eprintln!("{reason}");
        std::process::exit(1);
    });
    let mut refusals: Vec<Value> = Vec::new();
    let mut queries: Vec<Value> = Vec::new();

    let steps = script
        .get("steps")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    for step in steps {
        let args = step
            .get("args")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();

        if let Some(question) = step.get("query").and_then(Value::as_str) {
            match runtime.query(question, &args) {
                Ok(rows) => queries.push(json!({ "query": question, "args": args, "rows": rows })),
                Err(message) => {
                    queries.push(json!({ "query": question, "args": args, "error": message }))
                }
            }
            continue;
        }

        let verb = step.get("verb").and_then(Value::as_str).unwrap_or_default();
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
        "reactions": runtime.reactions,
        "sagas": runtime.sagas,
        "queries": queries,
    });

    // The run is REPORTED before it is JUDGED, exactly as bin/run reports it on
    // the Ruby side. A matrix expectation that fails says what was wanted and
    // never what happened — and exiting before the print takes the whole run's
    // evidence with it, so a refusal that merely changed its wording is
    // indistinguishable from a runtime that died. Print first ; complain after.
    println!("{}", serde_json::to_string_pretty(&output).unwrap());

    let unmet = enforce_expectations(&script, &output);
    if !unmet.is_empty() {
        eprintln!("matrix expectation failed: {}", unmet.join("\n"));
        std::process::exit(1);
    }
}

/// Every unmet expectation, not just the first. A script that has drifted has
/// usually drifted in more than one place, and reporting one at a time turns
/// one diagnosis into five runs.
fn enforce_expectations(script: &Value, output: &Value) -> Vec<String> {
    let mut unmet = Vec::new();
    let Some(expectations) = script.get("expectations").and_then(Value::as_object) else {
        return unmet;
    };

    let events = output
        .get("events")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for wanted in expectations
        .get("event_names")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
    {
        let Some(name) = wanted.as_str() else {
            continue;
        };
        if !events
            .iter()
            .any(|event| event.get("name").and_then(Value::as_str) == Some(name))
        {
            unmet.push(format!("event {:?} is missing", name));
        }
    }

    let refusals = output
        .get("refusals")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for expected in expectations
        .get("refusals")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
    {
        let verb = expected
            .get("verb")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let includes = expected
            .get("includes")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if !refusals.iter().any(|refusal| {
            refusal.get("verb").and_then(Value::as_str) == Some(verb)
                && refusal
                    .get("error")
                    .and_then(Value::as_str)
                    .is_some_and(|error| error.contains(includes))
        }) {
            // What DID that verb say? A refusal that changed its words is a
            // different story from a refusal that never happened, and the two
            // read identically until the actual errors are printed beside the
            // wanted one. Same reading bin/run prints on the Ruby side.
            let mut said: Vec<&str> = refusals
                .iter()
                .filter(|refusal| refusal.get("verb").and_then(Value::as_str) == Some(verb))
                .filter_map(|refusal| refusal.get("error").and_then(Value::as_str))
                .collect();
            said.dedup();
            unmet.push(format!(
                "refusal {:?} containing {:?} is missing\n  {} actually refused with: {}",
                verb,
                includes,
                verb,
                if said.is_empty() {
                    "(nothing — every attempt was accepted)".to_string()
                } else {
                    format!("{:?}", said)
                }
            ));
        }
    }

    let instances = output
        .get("instances")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    for (key, fields) in expectations
        .get("instances")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default()
    {
        let Some(actual) = instances.get(&key).and_then(Value::as_object) else {
            unmet.push(format!("instance {:?} is missing", key));
            continue;
        };
        for (field, expected) in fields.as_object().cloned().unwrap_or_default() {
            if actual.get(&field) != Some(&expected) {
                unmet.push(format!(
                    "{}.{} is not {} — it is {}",
                    key,
                    field,
                    expected,
                    actual.get(&field).unwrap_or(&Value::Null)
                ));
            }
        }
    }
    unmet
}

#[cfg(feature = "parser")]
fn read_bluebook(path: &str) -> Value {
    if !path.ends_with(".bluebook") {
        eprintln!(
            "{} is not a .bluebook — this runtime parses the native format",
            path
        );
        std::process::exit(2);
    }

    let source = fs::read_to_string(path).unwrap_or_else(|error| {
        eprintln!("cannot read {}: {}", path, error);
        std::process::exit(1);
    });

    ir_json::domain_to_value(&parser::parse(&source))
}

/// Translation IR for one edge file, or every edge in a `translations/`
/// directory — always an array, matching `bin/ir --translations` on the
/// Ruby side so the parity stage can diff the two readings directly.
fn read_translations(path: &str) -> Value {
    let path_buf = std::path::PathBuf::from(path);
    let files: Vec<std::path::PathBuf> = if path_buf.is_dir() {
        let mut found: Vec<std::path::PathBuf> = fs::read_dir(&path_buf)
            .unwrap_or_else(|error| {
                eprintln!("cannot read {}: {}", path, error);
                std::process::exit(1);
            })
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|candidate| {
                candidate
                    .extension()
                    .is_some_and(|extension| extension == "bluebook")
            })
            .collect();
        found.sort();
        found
    } else {
        vec![path_buf]
    };

    let translations: Vec<Value> = files
        .into_iter()
        .map(|file| {
            let source = fs::read_to_string(&file).unwrap_or_else(|error| {
                eprintln!("cannot read {}: {}", file.display(), error);
                std::process::exit(1);
            });
            let translation = storehouse::bluebook::translation::parser::parse(&source)
                .unwrap_or_else(|error| {
                    eprintln!("{error}");
                    std::process::exit(1);
                });
            storehouse::bluebook::translation::json::translation_to_value(&translation)
        })
        .collect();

    Value::Array(translations)
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
