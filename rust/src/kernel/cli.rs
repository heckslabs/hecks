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
// verb/args pair is handed to `kernel::orchestrate`, which recursively
// routes through `generated::active::dispatch_by_name`,
// `generated::active::POLICIES`, and `generated::active::PROCESS_MANAGERS`
// (rust/project/registry.rb's `emit_registry`, rust/project/reactions.rb's
// `emit_policy_table`/`emit_process_manager_table`) — the domain-agnostic
// alias `bin/project_rust` rewrites to point at whichever domain was last
// generated.

use super::{orchestrate, Event, Json, MutationRecord, Refusal, SagaInstance};
use crate::generated::active::{dispatch_by_name, reference_key_for_aggregate, Store, POLICIES, PROCESS_MANAGERS};
use std::collections::HashMap;

pub fn run(input: &str) -> String {
    let parsed = match Json::parse(input) {
        Ok(v) => v,
        Err(e) => return error_output(&format!("invalid JSON on stdin: {e}")),
    };

    let steps = match parsed.get("steps").and_then(Json::as_array) {
        Some(s) => s,
        None => return error_output("expected a top-level {\"steps\": [...]} object"),
    };

    // `"seed"` — the exact "Domain::Aggregate#id" -> state shape THIS
    // run's own "instances" output already produces (`Store::instances`/
    // `Store::from_seed`, mechanical inverses, `rust/project/registry.rb`'s
    // `emit_registry`). Optional and additive: an input with no `"seed"`
    // key behaves exactly as before (`Store::new()`, empty). Lets a HOST
    // (rust/host, docs/decisions/0012) seed prior state back in instead
    // of replaying `steps` from scratch every invocation — `steps` then
    // needs to carry only the genuinely new command(s), not the whole
    // history.
    let mut store = match parsed.get("seed") {
        Some(seed) => match Store::from_seed(seed) {
            Ok(s) => s,
            Err(refusal) => return error_output(&format!("invalid seed: {refusal}")),
        },
        None => Store::new(),
    };
    let mut events: Vec<Event> = Vec::new();
    let mut refusals: Vec<(String, Refusal)> = Vec::new();
    // Process-manager instances — domain-level, not per-aggregate, so
    // deliberately not a `Store` field (orchestrate.rs's own header).
    let mut sagas: HashMap<(String, String), SagaInstance> = HashMap::new();
    // One entry per step, in step order — a HOST driving this kernel
    // (rust/host, docs/decisions/0012) needs to know which records THIS
    // step's own dispatch (including everything it cascaded through
    // policies/sagas) actually saved, not just the whole-store snapshot
    // `instances` already reports. Kept parallel to `steps`, not flattened,
    // so a caller replaying prior history plus exactly one new step can
    // read `mutations.last()` for just the new step's own effect.
    let mut mutations_per_step: Vec<Vec<MutationRecord>> = Vec::new();

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
            mutations_per_step.push(Vec::new());
            continue;
        }

        let verb = match step.get("verb").and_then(Json::as_str) {
            Some(v) => v,
            None => return error_output("step missing \"verb\" or \"query\""),
        };

        let empty_args = Json::Object(vec![]);
        let args = step.get("args").unwrap_or(&empty_args);

        // `role:` — the SAME optional per-step key `Fuzzing::Replay.call`
        // reads (`lib/hecksagain/fuzzing/replay.rb`), now on this side of
        // the wire too: Ruby's caller is thread-local ambient state
        // (`Hecksagain.as_caller`) this kernel has no analogue for, so a
        // step's own `role:` plays that part instead — passed ONLY into
        // THIS top-level `orchestrate` call, never into a reaction's own
        // re-entry (`orchestrate.rs`'s own `None` at every recursive call
        // site mirrors `Dispatcher#reenter`'s `Caller.without`).
        let caller_role = step.get("role").and_then(Json::as_str);

        // `orchestrate` appends every event — this step's own AND every
        // policy reaction it triggers — into `events` itself; only the
        // TOP-level verb's own refusal is recorded per step, matching
        // `Fuzzing::Replay.call`'s own `rescue *Runtime::DOMAIN_REFUSALS`
        // scope (a reaction's downstream refusal is swallowed inside
        // `orchestrate`, never surfaced to this loop at all). A fresh
        // `Vec` per step, same reasoning as `all_events` being shared
        // across the WHOLE call but this one being per-step: mutations
        // triggered by a refused top-level command are real (a saga leg
        // that dispatched successfully before its sibling refused still
        // saved something) and stay recorded even though the step itself
        // is refused — matching `events`' own behavior one line above.
        let mut step_mutations: Vec<MutationRecord> = Vec::new();
        if let Err(refusal) = orchestrate(&mut store, dispatch_by_name, POLICIES, PROCESS_MANAGERS, reference_key_for_aggregate, &mut sagas, verb, args, caller_role, 0, &mut events, &mut step_mutations) {
            refusals.push((verb.to_string(), refusal));
        }
        mutations_per_step.push(step_mutations);
    }

    let events_json = Json::Array(events.iter().map(event_to_json).collect());
    let refusals_json = Json::Array(
        refusals
            .iter()
            .map(|(verb, r)| Json::obj(vec![("verb", Json::str(verb.clone())), ("error", Json::str(r.to_string()))]))
            .collect(),
    );
    let mutations_json = Json::Array(
        mutations_per_step
            .iter()
            .map(|step_mutations| Json::Array(step_mutations.iter().map(mutation_to_json).collect()))
            .collect(),
    );

    Json::Object(vec![
        ("instances".to_string(), Json::Object(store.instances())),
        ("events".to_string(), events_json),
        ("refusals".to_string(), refusals_json),
        ("mutations".to_string(), mutations_json),
    ])
    .to_json_string()
}

fn mutation_to_json(mutation: &MutationRecord) -> Json {
    Json::obj(vec![
        ("aggregate", Json::str(mutation.aggregate.clone())),
        ("id", Json::str(mutation.id.clone())),
        ("operation", Json::str(mutation.operation.to_string())),
        ("state", mutation.state.clone()),
    ])
}

fn event_to_json(event: &Event) -> Json {
    Json::obj(vec![
        ("name", Json::str(event.name.clone())),
        ("aggregate", Json::str(event.aggregate.clone())),
        ("id", Json::str(event.id.clone())),
        ("payload", event.payload.clone()),
    ])
}

fn error_output(message: &str) -> String {
    Json::obj(vec![("error", Json::str(message.to_string()))]).to_json_string()
}
