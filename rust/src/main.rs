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
//! language/bluebook/expression.bluebook.

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
#[allow(dead_code)]
mod ir;
#[allow(dead_code)]
mod parse_blocks;
#[allow(dead_code)]
mod parser;
#[allow(dead_code)]
mod parser_helpers;
#[allow(dead_code)]
mod pattern_subset;

mod ir_json;
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

    // `--dump <bluebook>` prints the IR this parser read, so it can be diffed
    // against the IR Ruby's parser read. Agreeing on BEHAVIOUR is good ;
    // agreeing on the IR itself is the stronger claim, because it shows the
    // two parsers understood the same document rather than two documents that
    // happened to run the same.
    if arguments.len() == 3 && arguments[1] == "--dump" {
        println!("{}", serde_json::to_string_pretty(&read_bluebook(&arguments[2])).unwrap());
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
