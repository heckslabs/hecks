
use storehouse::ports::persistence;
use storehouse::{dispatcher, dump, ir_json, parser};



use dispatcher::Runtime;
use serde_json::{json, Map, Value};
use std::fs;

fn main() {
    let arguments: Vec<String> = std::env::args().collect();

    if arguments.len() == 3 && arguments[1] == "--dump" {
        println!("{}", serde_json::to_string_pretty(&read_bluebook(&arguments[2])).unwrap());
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

    let ir = read_bluebook(&arguments[1]);
    let script = read_json(&arguments[2]);

    let mut runtime = Runtime::new(ir);

    for (name, aggregate) in runtime.aggregates() {
        let persistence = match persistence::resolve_for(&arguments[1], &name) {
            Ok(persistence) => persistence,
            Err(reason) => {
                eprintln!("{reason}");
                std::process::exit(1);
            }
        };

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
            }
            "Sqlite" => {
                let path = stored_at("database");

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
                Err(message) => queries.push(json!({ "query": question, "args": args, "error": message })),
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

    println!("{}", serde_json::to_string_pretty(&output).unwrap());
}

fn read_bluebook(path: &str) -> Value {
    if !path.ends_with(".bluebook") {
        eprintln!("{} is not a .bluebook — this runtime parses the native format", path);
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
