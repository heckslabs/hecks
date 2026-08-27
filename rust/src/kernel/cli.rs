// HAND-WRITTEN, ONCE, GENERIC — the stdin/stdout JSON CLI contract every
// compiled artifact speaks, native binary or wasm32-wasip1 module alike
// (WASI implements stdio the same way a normal process does — see
// docs/implemented/decisions/0012-wasm-via-wasi-stdio.md). Reads the exact
// `{"steps": [...]}` shape `bin/rust_conformance` already feeds Ruby's
// `Fuzzing::Replay.call`, and writes the exact `{"instances", "events",
// "refusals", "queries"}` shape `Fuzzing::Replay.call`'s own return hash
// already carries (`"queries"` is new — see this file's own header,
// below, on `run`'s two "query" step shapes) — SAME contract, now
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

use super::{named_query, orchestrate, query_comparators, read_model, repository, AggregateScan, Event, Json, MutationRecord, PendingCrossDomainReaction, Refusal, SagaInstance, Tables};
use crate::generated::active::{command_attributes_for_verb, command_creates, dispatch_by_name, identity_head_for_aggregate, reference_key_for_aggregate, Store, CROSS_DOMAIN_POLICIES, POLICIES, PROCESS_MANAGERS, QUERIES, READ_MODELS};
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
    // (rust/host, docs/implemented/decisions/0012) seed prior state back in instead
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
    //
    // `"sagas"` — optional and additive, the same contract `"seed"`
    // above already has: an input with no `"sagas"` key behaves exactly
    // as before (an empty map), backward compatible with every existing
    // caller (fuzzer, conformance harness) that never sends it. Lets a
    // HOST (rust/host) seed a domain's live in-flight saga state back
    // in, the same way `"seed"` already seeds aggregate state — see
    // this run's own `"saga_snapshot"` output key below for the other
    // half.
    let mut sagas: HashMap<(String, String), SagaInstance> = match parsed.get("sagas").and_then(Json::as_array) {
        Some(entries) => entries
            .iter()
            .filter_map(|entry| {
                let process_manager = entry.get("process_manager")?.as_str()?.to_string();
                let correlation = entry.get("correlation")?.as_str()?.to_string();
                let state = entry.get("state")?.as_str()?.to_string();
                let memory = entry.get("memory").cloned().unwrap_or_else(|| Json::Object(vec![]));
                Some(((process_manager, correlation), SagaInstance { state, memory }))
            })
            .collect(),
        None => HashMap::new(),
    };
    // One entry per step, in step order — a HOST driving this kernel
    // (rust/host, docs/implemented/decisions/0012) needs to know which records THIS
    // step's own dispatch (including everything it cascaded through
    // policies/sagas) actually saved, not just the whole-store snapshot
    // `instances` already reports. Kept parallel to `steps`, not flattened,
    // so a caller replaying prior history plus exactly one new step can
    // read `mutations.last()` for just the new step's own effect.
    let mut mutations_per_step: Vec<Vec<MutationRecord>> = Vec::new();
    // One entry per step, parallel to `mutations_per_step` — this
    // module's own honest confession (orchestrate.rs's header) that a
    // policy fired but named a domain this compiled `Store` never
    // included, so nothing here could deliver it. rust/host reads only
    // `.last()`, the same "just the newly-dispatched step" rule
    // `mutations`'s own doc comment already states, and is the one place
    // actually equipped to finish the job (`lambda_client.rs`).
    let mut cross_domain_per_step: Vec<Vec<PendingCrossDomainReaction>> = Vec::new();
    // FLAT, whole-run accumulation — like `events`/`all_events` above,
    // NOT per-step like `mutations_per_step`/`cross_domain_per_step`.
    // Matches `Registry#reaction_log`/`#saga_log` exactly: Ruby accumulates
    // these across the WHOLE boot, never resets them per dispatched step,
    // and `Fuzzing::Replay.call`'s own return hash (`reactions: runtime.
    // reactions, sagas: runtime.sagas`) reports the whole-run total the
    // same way.
    let mut reaction_log: Vec<Json> = Vec::new();
    let mut saga_log: Vec<Json> = Vec::new();
    // One entry per successfully-answered "query" step, in step order —
    // Fuzzing::Replay's own `queries` array (lib/hecks/fuzzing/
    // replay.rb), read directly: a REFUSED query step (either shape)
    // reports through `refusals` above instead, exactly like a refused
    // command does, and contributes nothing here — matching Ruby, which
    // never pushes a `rows:`-bearing entry for a question that raised.
    let mut query_results: Vec<Json> = Vec::new();
    // One entry per "dry_run" step, in step order — `Dispatcher#dry_run?`
    // (Ruby): the command evaluated hypothetically, givens/mutations/
    // ensures for real, nothing saved, nothing emitted, no reaction. Here:
    // the same dispatch against a throwaway clone of the store.
    let mut dry_runs: Vec<Json> = Vec::new();

    for step in steps {
        // Read once, ahead of the "query"/"verb" branch below — a query
        // step's own `args` (Fuzzing::Replay's `runtime.query(question,
        // **args)`) lives at this SAME sibling `"args"` key a command step
        // already reads, never inside the `"query"` value itself.
        let empty_args = Json::Object(vec![]);
        let args = step.get("args").unwrap_or(&empty_args);

        // A `"query"` step (Fuzzing::Replay's other real shape,
        // `step["query"]` instead of `step["verb"]` — a query step carries
        // no verb at all) has TWO shapes on the wire, checked BEFORE
        // requiring "verb" below since a query step legitimately has none:
        //
        //   STRING  — a NAMED/declared bluebook ask, and it has TWO real
        //   sub-shapes of its own, told apart by whether "::" appears
        //   before the first "." — the exact same test `Runtime::
        //   Dispatcher#query` makes (`domain, query_name =
        //   verb.to_s.split(".", 2); if query_name && !domain.include?
        //   ("::")` — a bare "Domain.Name" is a read model, everything
        //   else falls through to the aggregate-query parse):
        //
        //     "Banking::CardPayment.Pending" (contains "::") — a query on
        //     ONE aggregate, Fuzzing::Replay's original shape. Executes
        //     for real, as of `rust/project/queries.rb`/`kernel/
        //     named_query.rs`, for whichever declared queries this
        //     compiled domain's own `QUERIES` table (rust/project/
        //     registry.rb's `emit_query_table`) carries a row for — the
        //     subset expressible as one or more field-comparator
        //     conditions against a single aggregate's OWN attributes
        //     (queries.rb's own header has the full eligibility argument:
        //     no order_by/limit/cursor/.../index_hints, no reference-
        //     hopping where clause, no type-unrecoverable literal
        //     comparator).
        //
        //     "Banking.CustomerPortfolio" (no "::") — a READ MODEL, a
        //     cross-aggregate ask spined on a root fetched by reference id
        //     (`IR::ReadModel`). Executes for real, as of `rust/project/
        //     read_models.rb`/`kernel/read_model.rs`, for whichever
        //     declared read models this compiled domain's own
        //     `READ_MODELS` table carries a row for — a root aggregate
        //     fetched by reference id plus reference-matched sibling
        //     heads, no `where`/`order_by`/`limit`/`offset`/`cursor`/
        //     `consistency`/`freshness`/`authorize`/`nulls`/
        //     `inspect_query`/`use_index` (read_models.rb's own header has
        //     the full eligibility argument, including why `where`/
        //     `order_by`/`limit` specifically are a STRUCTURAL gap in the
        //     canonical IR itself, not merely unported). Unlike a named
        //     aggregate query, a read model has no reference-interpreter
        //     twin at all (`Runtime::Dispatcher#reference_query`'s own
        //     comment: "Read models have no reference twin"), so its own
        //     `queries` entry carries `"reference_rows": null` always,
        //     never a computed second answer — matching `Fuzzing::
        //     Replay`'s own `reference = question.include?("::") ?
        //     runtime.reference_query(...) : nil` exactly.
        //
        //   Either sub-shape, a question its own table carries no row for
        //   — genuinely unknown, or a real declared query/read model whose
        //   shape this generator doesn't cover — refuses cleanly, the same
        //   `Refusal::TypeMismatch` an unrouted verb already gets.
        //
        //   OBJECT  — an AD HOC, single-comparator filter ({"aggregate",
        //   "field", "op", "value"}). Executes for real: `run_filter`
        //   (below) resolves the named aggregate against THIS compiled
        //   domain's own `Store` (`AggregateScan`, kernel/repository.rs),
        //   validates `op` against the eight real `QueryComparator`
        //   variants (query_comparators.rs), and filters that one
        //   aggregate's own stored instances. Anything this shape doesn't
        //   cover — an unrecognized comparator, an aggregate this compiled
        //   domain doesn't recognize (including, honestly, a domain never
        //   regenerated with scan support at all — AggregateScan's own
        //   default) — refuses cleanly too, never a wrong (empty-but-
        //   silent) answer and never a panic.
        if let Some(query) = step.get("query") {
            match query {
                Json::Str(question) if question.contains("::") => match named_query::find(QUERIES, question) {
                    Some(def) => match named_query::run(&store, def, args) {
                        Ok(entries) => {
                            let rows = Json::Array(entries.into_iter().map(|(id, record)| repository::row_json(id, record)).collect());
                            query_results.push(Json::obj(vec![
                                ("query", Json::Str(question.clone())),
                                ("args", args.clone()),
                                ("rows", rows.clone()),
                                // PROVABLY equal to `rows`, not merely
                                // assumed — see named_query.rs's own
                                // "GROUND TRUTH" paragraph for the exact
                                // property this leans on: every row this
                                // table ever holds is, by `queries.rb`'s
                                // own eligibility gate, hop-free and
                                // order-free, which is exactly the
                                // condition under which Ruby's `interpret`
                                // and `reference_interpret` are the
                                // identical answer.
                                ("reference_rows", rows),
                            ]));
                        }
                        Err(refusal) => refusals.push((question.clone(), refusal)),
                    },
                    None => refusals.push((
                        question.clone(),
                        Refusal::TypeMismatch(format!(
                            "named/declared query {question:?} is not generated for this domain — either unknown, or a \
                             real declared query whose shape this generator's codegen doesn't cover yet (order_by/limit/\
                             cursor/consistency/freshness/authorization/null_semantics/inspection/index_hints, a where \
                             clause hopping through a reference, or a literal comparator value whose true JSON type \
                             can't be recovered from the exported IR — rust/project/queries.rb's own header has the \
                             full argument); the wheres-only, single-aggregate field-comparator subset and the ad hoc \
                             filter shape ({{\"aggregate\",\"field\",\"op\",\"value\"}}) both execute for real"
                        )),
                    )),
                },
                Json::Str(question) => match read_model::find(READ_MODELS, question) {
                    Some(def) => match read_model::run(&store, def, args) {
                        Ok(row) => {
                            query_results.push(Json::obj(vec![
                                ("query", Json::Str(question.clone())),
                                ("args", args.clone()),
                                ("rows", Json::Array(vec![row])),
                                // A read model has no reference-interpreter
                                // twin at all — see this block's own header.
                                // `reference_rows` is OMITTED, not present-
                                // as-`null`: `Fuzzing::Replay#call`
                                // (lib/hecks/fuzzing/replay.rb) only does
                                // `entry[:reference_rows] = reference_rows`
                                // inside its own `if has_reference` guard,
                                // so Ruby's own queries entry for a bare
                                // (non-"::") question never gains the key
                                // at all — confirmed directly, not assumed.
                                // Ruby is the oracle (docs/decisions/
                                // 0010-ruby-is-the-reference-implementation.md);
                                // this key used to claim to match that
                                // exactly while actually always including
                                // it, which it didn't.
                            ]));
                        }
                        Err(refusal) => refusals.push((question.clone(), refusal)),
                    },
                    None => refusals.push((
                        question.clone(),
                        Refusal::TypeMismatch(format!(
                            "named/declared read model {question:?} is not generated for this domain — either unknown, \
                             or a real declared read model whose shape this generator's codegen doesn't cover yet \
                             (anything beyond a root aggregate fetched by reference id plus reference-matched sibling \
                             heads — where/order_by/limit/offset/cursor/consistency/freshness/authorize(TenantScope)/\
                             nulls/inspect_query/use_index — rust/project/read_models.rb's own header has the full \
                             argument, including why where/order_by/limit specifically can never be recovered from the \
                             canonical IR at all); the named/declared AGGREGATE query form (\"Domain::Aggregate.Query\") \
                             and the ad hoc filter shape ({{\"aggregate\",\"field\",\"op\",\"value\"}}) both execute for \
                             real too"
                        )),
                    )),
                },
                Json::Object(_) => match run_filter(&store, query) {
                    Ok(rows) => query_results.push(Json::obj(vec![("query", query.clone()), ("rows", Json::Array(rows))])),
                    Err(refusal) => refusals.push((filter_label(query), refusal)),
                },
                _ => refusals.push((
                    "query".to_string(),
                    Refusal::TypeMismatch("a \"query\" step must be a string (named ask) or an object (ad hoc filter)".to_string()),
                )),
            }
            mutations_per_step.push(Vec::new());
            cross_domain_per_step.push(Vec::new());
            continue;
        }

        if let Some(verb) = step.get("dry_run").and_then(Json::as_str) {
            let caller_role = step.get("role").and_then(Json::as_str);
            let command_input = command_input(step, args);
            dry_runs.push(dry_run(&store, verb, command_input, caller_role));
            mutations_per_step.push(Vec::new());
            cross_domain_per_step.push(Vec::new());
            continue;
        }

        let verb = match step.get("verb").and_then(Json::as_str) {
            Some(v) => v,
            None => return error_output("step missing \"verb\", \"dry_run\", or \"query\""),
        };

        // `role:` — the SAME optional per-step key `Fuzzing::Replay.call`
        // reads (`lib/hecks/fuzzing/replay.rb`), now on this side of
        // the wire too: Ruby's caller is thread-local ambient state
        // (`Hecks.as_caller`) this kernel has no analogue for, so a
        // step's own `role:` plays that part instead — passed ONLY into
        // THIS top-level `orchestrate` call, never into a reaction's own
        // re-entry (`orchestrate.rs`'s own `None` at every recursive call
        // site mirrors `Dispatcher#reenter`'s `Caller.without`).
        let caller_role = step.get("role").and_then(Json::as_str);

        // Direct callers use top-level `to`/`with`; the durable host wraps
        // that same object under its historical `args` journal column so no
        // storage migration is required. Generated `dispatch_by_name`
        // accepts either location through `CommandInvocation`.
        let command_input = command_input(step, args);

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
        let mut step_cross_domain: Vec<PendingCrossDomainReaction> = Vec::new();
        let tables = Tables {
            policies: POLICIES,
            cross_domain_policies: CROSS_DOMAIN_POLICIES,
            process_managers: PROCESS_MANAGERS,
            reference_key_fn: reference_key_for_aggregate,
            queries: QUERIES,
            command_creates_fn: command_creates,
            identity_head_fn: identity_head_for_aggregate,
            command_attributes_fn: command_attributes_for_verb,
        };
        if let Err(refusal) = orchestrate(
            &mut store,
            dispatch_by_name,
            tables,
            &mut sagas,
            verb,
            command_input,
            caller_role,
            None,
            0,
            &mut events,
            &mut step_mutations,
            &mut step_cross_domain,
            &mut reaction_log,
            &mut saga_log,
        ) {
            refusals.push((verb.to_string(), refusal));
        }
        mutations_per_step.push(step_mutations);
        cross_domain_per_step.push(step_cross_domain);
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
    let cross_domain_json = Json::Array(
        cross_domain_per_step
            .iter()
            .map(|step_reactions| Json::Array(step_reactions.iter().map(cross_domain_reaction_to_json).collect()))
            .collect(),
    );

    Json::Object(vec![
        ("instances".to_string(), Json::Object(store.instances())),
        ("events".to_string(), events_json),
        ("refusals".to_string(), refusals_json),
        ("dry_runs".to_string(), Json::Array(dry_runs)),
        ("mutations".to_string(), mutations_json),
        ("queries".to_string(), Json::Array(query_results)),
        ("cross_domain_reactions".to_string(), cross_domain_json),
        // `Registry#reaction_log`/`#saga_log`, read directly — see
        // reaction_log/saga_log's own declaration above for why these are
        // flat (whole-run) rather than per-step like `mutations`/
        // `cross_domain_reactions`.
        ("reactions".to_string(), Json::Array(reaction_log)),
        ("sagas".to_string(), Json::Array(saga_log)),
        // A LIVE SNAPSHOT of `sagas` as it stands at the end of this
        // run — deliberately a separate key from `"sagas"` above, which
        // is the flat transition LOG (every attempted transition, even
        // refused ones), not a snapshot of current state. Same
        // relationship `"instances"` already has to `"events"`: one is
        // "what happened," the other is "what's true now." A host
        // (rust/host) persists this the same way it already persists
        // `"instances"`, and feeds it back in as this run's own
        // `"sagas"` INPUT key next time (see above).
        ("saga_snapshot".to_string(), saga_snapshot_json(&sagas)),
    ])
    .to_json_string()
}

/// THE AD HOC FILTER'S OWN DISPATCH — `{"aggregate", "field", "op",
/// "value"}`, every key required (a missing one refuses via `Json::
/// require`, the same message shape every generated `from_json` already
/// uses). `aggregate` is looked up through `AggregateScan::scan`
/// (kernel/repository.rs), generated per compiled domain; `op` through
/// `QueryComparator::parse` (query_comparators.rs) — either miss refuses
/// with a clear, specific reason, never falls through to an empty-but-
/// silent result. `value`'s own JSON type rides straight through
/// unchanged (a caller means whatever type they wrote — a bare JSON
/// number for a numeric comparator, a string, `null` for a genuine nil
/// check) all the way into `repository::filter_entries`, which is the
/// one place it's actually interpreted.
/// `Dispatcher#dry_run?` — evaluate a command against a throwaway copy
/// of the store. `{"verb", "ok"}` or `{"verb", "ok": false, "error"}`,
/// the error being the very refusal a real dispatch would have raised.
fn dry_run(store: &Store, verb: &str, command_input: &Json, caller_role: Option<&str>) -> Json {
    let mut scratch = store.clone();
    match dispatch_by_name(&mut scratch, verb, command_input, caller_role, &mut Vec::new()) {
        Ok(_) => Json::obj(vec![("verb", Json::str(verb.to_string())), ("ok", Json::Bool(true))]),
        Err(refusal) => Json::obj(vec![("verb", Json::str(verb.to_string())), ("ok", Json::Bool(false)), ("error", Json::str(refusal.to_string()))]),
    }
}

fn tables() -> Tables<'static> {
    Tables {
        policies: POLICIES,
        cross_domain_policies: CROSS_DOMAIN_POLICIES,
        process_managers: PROCESS_MANAGERS,
        reference_key_fn: reference_key_for_aggregate,
        queries: QUERIES,
        command_creates_fn: command_creates,
        identity_head_fn: identity_head_for_aggregate,
        command_attributes_fn: command_attributes_for_verb,
    }
}

/// THE STREAMING MODE — `rust --serve`: one JSON step per stdin line, one
/// JSON answer per stdout line, the store alive across them. What a
/// move CHOOSER needs from a referee (hecks_ai_training's bin/selfplay):
/// propose with `{"dry_run": verb, "args": …}` as many times as it likes,
/// commit with `{"verb": …}`, read the board with `{"instances": true}`,
/// and try a multi-dispatch sequence (a capture is two) between
/// `{"snapshot": true}` and `{"restore": true}` — the same throwaway-copy
/// idea as a dry run, held open across steps. Reactions run on commits
/// exactly as in `run`; answers carry the events each commit produced.
pub fn serve(input: impl std::io::BufRead, mut output: impl std::io::Write) {
    let mut store = Store::new();
    let mut sagas: HashMap<(String, String), SagaInstance> = HashMap::new();
    let mut reaction_log: Vec<Json> = Vec::new();
    let mut saga_log: Vec<Json> = Vec::new();
    let mut snapshot: Option<(Store, HashMap<(String, String), SagaInstance>)> = None;
    let ok = || Json::obj(vec![("ok", Json::Bool(true))]);

    for line in input.lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let answer = match Json::parse(&line) {
            Err(e) => Json::obj(vec![("ok", Json::Bool(false)), ("error", Json::str(format!("invalid JSON: {e}")))]),
            Ok(step) => {
                let empty_args = Json::Object(vec![]);
                let args = step.get("args").unwrap_or(&empty_args);
                let caller_role = step.get("role").and_then(Json::as_str);
                if step.get("snapshot").is_some() {
                    snapshot = Some((store.clone(), sagas.clone()));
                    ok()
                } else if step.get("restore").is_some() {
                    match &snapshot {
                        Some((s, g)) => {
                            store = s.clone();
                            sagas = g.clone();
                            ok()
                        }
                        None => Json::obj(vec![("ok", Json::Bool(false)), ("error", Json::str("no snapshot to restore"))]),
                    }
                } else if step.get("instances").is_some() {
                    Json::obj(vec![("ok", Json::Bool(true)), ("instances", Json::Object(store.instances()))])
                } else if let Some(verb) = step.get("dry_run").and_then(Json::as_str) {
                    dry_run(&store, verb, command_input(&step, args), caller_role)
                } else if let Some(verb) = step.get("verb").and_then(Json::as_str) {
                    let mut events: Vec<Event> = Vec::new();
                    let outcome = orchestrate(
                        &mut store,
                        dispatch_by_name,
                        tables(),
                        &mut sagas,
                        verb,
                        command_input(&step, args),
                        caller_role,
                        None,
                        0,
                        &mut events,
                        &mut Vec::new(),
                        &mut Vec::new(),
                        &mut reaction_log,
                        &mut saga_log,
                    );
                    match outcome {
                        Ok(()) => Json::obj(vec![("ok", Json::Bool(true)), ("events", Json::Array(events.iter().map(event_to_json).collect()))]),
                        Err(refusal) => Json::obj(vec![("ok", Json::Bool(false)), ("error", Json::str(refusal.to_string()))]),
                    }
                } else {
                    Json::obj(vec![("ok", Json::Bool(false)), ("error", Json::str("step needs verb, dry_run, snapshot, restore, or instances"))])
                }
            }
        };
        if writeln!(output, "{}", answer.to_json_string()).is_err() || output.flush().is_err() {
            break;
        }
    }
}

fn run_filter(store: &Store, filter: &Json) -> Result<Vec<Json>, Refusal> {
    let aggregate = required_str(filter, "aggregate")?;
    let field = required_str(filter, "field")?;
    let op = required_str(filter, "op")?;
    let value = filter.require("value", "query filter")?;

    let comparator = query_comparators::QueryComparator::parse(op)
        .ok_or_else(|| Refusal::TypeMismatch(format!("unknown query comparator {op:?}")))?;
    let entries = store
        .scan(aggregate)
        .ok_or_else(|| Refusal::TypeMismatch(format!("unknown aggregate {aggregate:?}")))?;

    let matched = repository::filter_entries(entries, field, comparator, value);
    Ok(matched.into_iter().map(|(id, record)| repository::row_json(id, record)).collect())
}

fn required_str<'a>(filter: &'a Json, key: &str) -> Result<&'a str, Refusal> {
    filter
        .require(key, "query filter")?
        .as_str()
        .ok_or_else(|| Refusal::TypeMismatch(format!("query filter {key:?} must be a string")))
}

/// The `refusals` entry's own "verb" column, for a REFUSED ad hoc filter
/// — there is no real verb to report (a filter step carries no verb at
/// all), so this builds the same descriptive label Fuzzing::Replay's own
/// mirror-image Ruby code builds from the same three raw fields, tolerant
/// of any of them being absent or the wrong shape (a malformed filter is
/// exactly the case this label most needs to describe without itself
/// panicking) — `Json::as_str` on a missing/non-string field reads as
/// `None`, folded to `""` here the same way Ruby's own string
/// interpolation folds a missing/nil hash value.
fn filter_label(filter: &Json) -> String {
    let field = |key: &str| filter.get(key).and_then(Json::as_str).unwrap_or("");
    format!("filter {}.{} {}", field("aggregate"), field("field"), field("op"))
}

fn command_input<'a>(step: &'a Json, legacy_args: &'a Json) -> &'a Json {
    if step.get("to").is_some() || step.get("with").is_some() {
        step
    } else {
        legacy_args
    }
}

fn mutation_to_json(mutation: &MutationRecord) -> Json {
    Json::obj(vec![
        ("aggregate", Json::str(mutation.aggregate.clone())),
        ("id", Json::str(mutation.id.clone())),
        ("operation", Json::str(mutation.operation.to_string())),
        ("state", mutation.state.clone()),
    ])
}

/// One `PendingCrossDomainReaction` (orchestrate.rs), on the wire —
/// exactly the four fields rust/host's `lambda_client.rs` needs to
/// finish delivering what this sandboxed module could only match, not
/// route: which policy fired, which domain's Lambda to invoke, which
/// verb to invoke it with, and the event's own payload, forwarded
/// verbatim (this file's own `react_policies` comment on "not reshaped,
/// not filtered" — the identical rule, just carried out one layer up).
fn cross_domain_reaction_to_json(reaction: &PendingCrossDomainReaction) -> Json {
    Json::obj(vec![
        ("policy", Json::str(reaction.policy_name.clone())),
        ("target_domain", Json::str(reaction.target_domain.clone())),
        ("target_verb", Json::str(reaction.target_verb.clone())),
        ("payload", reaction.payload.clone()),
    ])
}

/// The live `sagas` map, dumped as a JSON array of the same shape the
/// `"sagas"` INPUT key (above) parses — round-trippable: what this
/// function emits is exactly what a later `run` call, given it back as
/// `"sagas"`, would parse into an identical map.
fn saga_snapshot_json(sagas: &HashMap<(String, String), SagaInstance>) -> Json {
    Json::Array(
        sagas
            .iter()
            .map(|((process_manager, correlation), instance)| {
                Json::obj(vec![
                    ("process_manager", Json::str(process_manager.clone())),
                    ("correlation", Json::str(correlation.clone())),
                    ("state", Json::str(instance.state.clone())),
                    ("memory", instance.memory.clone()),
                ])
            })
            .collect(),
    )
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

#[cfg(test)]
mod routing_tests {
    use super::*;

    #[test]
    fn top_level_with_selects_an_unrouted_compound_create_invocation() {
        let step = Json::obj(vec![
            ("verb", Json::str("Banking::SafeDepositBox.Rent")),
            (
                "with",
                Json::obj(vec![
                    ("branch_code", Json::str("DOWNTOWN")),
                    ("box_number", Json::int(12)),
                ]),
            ),
        ]);
        let legacy_args = Json::obj(vec![]);

        let selected = command_input(&step, &legacy_args);
        let invocation = crate::kernel::CommandInvocation::from_json(selected).unwrap();
        assert_eq!(invocation.route(), None);
        assert_eq!(invocation.facts().get("branch_code").and_then(Json::as_str), Some("DOWNTOWN"));
        assert_eq!(invocation.facts().get("box_number").and_then(Json::as_i64), Some(12));
    }
}
