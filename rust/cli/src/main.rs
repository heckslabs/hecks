use storehouse::ports::persistence;
use storehouse::{dispatcher, dump, ir_json, parser};

use dispatcher::Runtime;
use serde_json::{json, Map, Value};
use std::fs;

fn main() {
    let arguments: Vec<String> = std::env::args().collect();

    if arguments.len() == 3 && arguments[1] == "--dump" {
        println!(
            "{}",
            serde_json::to_string_pretty(&read_bluebook(&arguments[2])).unwrap()
        );
        return;
    }

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

    let script = read_json(&arguments[2]);
    storehouse_sqlite::register();
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

    if let Err(reason) = enforce_expectations(&script, &output) {
        eprintln!("matrix expectation failed: {reason}");
        std::process::exit(1);
    }

    println!("{}", serde_json::to_string_pretty(&output).unwrap());
}

fn enforce_expectations(script: &Value, output: &Value) -> Result<(), String> {
    let Some(expectations) = script.get("expectations").and_then(Value::as_object) else {
        return Ok(());
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
            return Err(format!("event {:?} is missing", name));
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
            return Err(format!(
                "refusal {:?} containing {:?} is missing",
                verb, includes
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
        let actual = instances
            .get(&key)
            .and_then(Value::as_object)
            .ok_or_else(|| format!("instance {:?} is missing", key))?;
        for (field, expected) in fields.as_object().cloned().unwrap_or_default() {
            if actual.get(&field) != Some(&expected) {
                return Err(format!("{}.{} is not {}", key, field, expected));
            }
        }
    }
    Ok(())
}

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
