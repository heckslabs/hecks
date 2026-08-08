// HAND-WRITTEN, ONCE, GENERIC — the stdin/stdout JSON CLI contract every
// compiled artifact speaks, native binary or wasm32-wasip1 module alike
// (WASI implements stdio the same way a normal process does — see
// docs/decisions/0012-wasm-via-wasi-stdio.md). Reads the exact
// `{"steps": [...]}` shape `bin/rust_conformance` already feeds Ruby's
// `Fuzzing::Replay.call`, and writes the exact `{"instances", "events",
// "refusals"}` shape it already prints from Ruby — SAME contract, now
// answerable by this compiled artifact too, not only a pre-existing file
// (`bin/rust_conformance`'s own header comment: "this tool does not invoke
// Rust itself... until then, 'give me a JSON file to compare against' is
// the whole interface"). `run` knows nothing domain-specific — every
// verb/args pair is handed to `generated::active::dispatch_by_name`
// (rust/project/registry.rb's `emit_registry`), the one alias
// `bin/project_rust` rewrites to point at whichever domain was last
// generated.

use super::{Event, Json, Refusal};
use crate::generated::active::{dispatch_by_name, Store};

pub fn run(input: &str) -> String {
    let parsed = match Json::parse(input) {
        Ok(v) => v,
        Err(e) => return error_output(&format!("invalid JSON on stdin: {e}")),
    };

    let steps = match parsed.get("steps").and_then(Json::as_array) {
        Some(s) => s,
        None => return error_output("expected a top-level {\"steps\": [...]} object"),
    };

    let mut store = Store::new();
    let mut events: Vec<Event> = Vec::new();
    let mut refusals: Vec<(String, Refusal)> = Vec::new();

    for step in steps {
        // A `"query"` step (Fuzzing::Replay's other real shape,
        // `step["query"]` instead of `step["verb"]` — a query step carries
        // no verb at all) has no Rust-side counterpart yet — no
        // query/read-model codegen exists (§8's own "what actually got
        // built" list). Refused the same way an unrouted command name is,
        // not silently ignored — checked BEFORE requiring "verb" below,
        // since a query step legitimately has none.
        if let Some(question) = step.get("query").and_then(Json::as_str) {
            refusals.push((question.to_string(), Refusal::TypeMismatch("query steps are not generated yet".to_string())));
            continue;
        }

        let verb = match step.get("verb").and_then(Json::as_str) {
            Some(v) => v,
            None => return error_output("step missing \"verb\" or \"query\""),
        };

        let empty_args = Json::Object(vec![]);
        let args = step.get("args").unwrap_or(&empty_args);

        match dispatch_by_name(&mut store, verb, args) {
            Ok(mut emitted) => events.append(&mut emitted),
            Err(refusal) => refusals.push((verb.to_string(), refusal)),
        }
    }

    let events_json = Json::Array(events.iter().map(event_to_json).collect());
    let refusals_json = Json::Array(
        refusals
            .iter()
            .map(|(verb, r)| Json::obj(vec![("verb", Json::str(verb.clone())), ("error", Json::str(r.to_string()))]))
            .collect(),
    );

    Json::Object(vec![
        ("instances".to_string(), Json::Object(store.instances())),
        ("events".to_string(), events_json),
        ("refusals".to_string(), refusals_json),
    ])
    .to_json_string()
}

fn event_to_json(event: &Event) -> Json {
    let payload = Json::Object(event.payload.iter().map(|(k, v)| (k.clone(), Json::Str(v.clone()))).collect());
    Json::obj(vec![
        ("name", Json::str(event.name.clone())),
        ("aggregate", Json::str(event.aggregate.clone())),
        ("id", Json::str(event.id.clone())),
        ("payload", payload),
    ])
}

fn error_output(message: &str) -> String {
    Json::obj(vec![("error", Json::str(message.to_string()))]).to_json_string()
}
