//! hecksagain - the Rust runtime.
//!
//!   hecksagain <ir.json> <script.json>
//!
//! Reads an IR that Ruby produced and a script of commands, runs them, and
//! prints the result as JSON. Its Ruby counterpart (bin/run) takes the same two
//! files and prints the same shape, so the two outputs can be diffed directly.
//!
//! This binary contains no knowledge of any particular domain. It never parses
//! a bluebook - parsing the bluebook twice, once per language, is the exact
//! mistake hecksagain exists to avoid. Ruby is the only parser; this reads what
//! Ruby produced.

mod dispatcher;
mod interp_expr;
mod interp_givens;
mod interp_mutations;

#[cfg(test)]
mod interp_tests;

use dispatcher::Runtime;
use serde_json::{json, Map, Value};
use std::fs;

fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.len() < 3 {
        eprintln!("usage: hecksagain <ir.json> <script.json>");
        std::process::exit(2);
    }

    let ir = read_json(&arguments[1]);
    let script = read_json(&arguments[2]);

    let mut runtime = Runtime::new(ir);
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
    });

    println!("{}", serde_json::to_string_pretty(&output).unwrap());
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
