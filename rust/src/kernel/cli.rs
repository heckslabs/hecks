//! The stdin/stdout JSON CLI shared by the native binary and the wasm32-wasip1 module.
//! `run` reads `{"steps": [...]}` and hands each step to `kernel::orchestrate` (ADR 0012).

use super::{named_query, orchestrate, query_comparators, read_model, repository, AggregateScan, CompletedCompensation, Event, Json, MutationRecord, PendingCrossDomainReaction, Refusal, SagaInstance, Tables};
use crate::generated::active::{command_attributes_for_verb, command_creates, dispatch_by_name, entity_identity_head_for_path, identity_head_for_aggregate, reference_key_for_aggregate, Store, CROSS_DOMAIN_POLICIES, POLICIES, PROCESS_MANAGERS, QUERIES, READ_MODELS};
use std::collections::HashMap;

// Builds and invariant-checks a named query's value-object arguments (ADR 0037).
use crate::generated::active::check_query_args;

use crate::generated::active::ENTITY_QUERIES;

pub fn run(input: &str) -> String {
    let parsed = match Json::parse(input) {
        Ok(v) => v,
        Err(e) => return error_output(&format!("invalid JSON on stdin: {e}")),
    };

    let steps = match parsed.get("steps").and_then(Json::as_array) {
        Some(s) => s,
        None => return error_output("expected a top-level {\"steps\": [...]} object"),
    };

    // Optional `"seed"`: prior state as `"instances"` emits it, so a host need not replay history.
    let mut store = match parsed.get("seed") {
        Some(seed) => match Store::from_seed(seed) {
            Ok(s) => s,
            Err(refusal) => return error_output(&format!("invalid seed: {refusal}")),
        },
        None => Store::new(),
    };
    let mut events: Vec<Event> = Vec::new();
    let mut refusals: Vec<(String, Refusal)> = Vec::new();
    // Process-manager instances are domain-level, so not a `Store` field.
    // Optional `"sagas"` seeds in-flight saga state the way `"seed"` seeds aggregates.
    let mut sagas: HashMap<(String, String), SagaInstance> = match parsed.get("sagas").and_then(Json::as_array) {
        Some(entries) => entries
            .iter()
            .filter_map(|entry| {
                let process_manager = entry.get("process_manager")?.as_str()?.to_string();
                let correlation = entry.get("correlation")?.as_str()?.to_string();
                let state = entry.get("state")?.as_str()?.to_string();
                let memory = entry.get("memory").cloned().unwrap_or_else(|| Json::Object(vec![]));
                // Optional: an instance persisted without a ledger rehydrates with an empty one.
                let completed_compensations = entry
                    .get("completed_compensations")
                    .and_then(Json::as_array)
                    .map(|entries| {
                        entries
                            .iter()
                            .filter_map(|e| {
                                let command_name = e.get("command_name")?.as_str()?.to_string();
                                let args = e.get("args").cloned().unwrap_or(Json::Null);
                                Some(CompletedCompensation { command_name, args })
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                Some(((process_manager, correlation), SagaInstance { state, memory, completed_compensations }))
            })
            .collect(),
        None => HashMap::new(),
    };
    // One entry per step, parallel to `steps`, so a host can read `.last()` for the newest step.
    let mut mutations_per_step: Vec<Vec<MutationRecord>> = Vec::new();
    // Parallel to `mutations_per_step`: policies that named a domain not compiled into this
    // `Store`; rust/host delivers them.
    let mut cross_domain_per_step: Vec<Vec<PendingCrossDomainReaction>> = Vec::new();
    // Whole-run accumulations matching `Registry#reaction_log`/`#saga_log`; never reset per step.
    let mut reaction_log: Vec<Json> = Vec::new();
    let mut saga_log: Vec<Json> = Vec::new();
    // One entry per answered `query` step; a refused query goes to `refusals` instead.
    let mut query_results: Vec<Json> = Vec::new();
    // One entry per `dry_run` step: the command run against a throwaway clone of the store.
    let mut dry_runs: Vec<Json> = Vec::new();

    for step in steps {
        // A query step's `args` sit at the sibling `"args"` key, as for a command step.
        let empty_args = Json::Object(vec![]);
        let args = step.get("args").unwrap_or(&empty_args);

        // A `"query"` step carries no verb and takes one of three shapes:
        //   - `"Domain::Aggregate.Query"`: a declared aggregate query, looked up in `QUERIES`.
        //   - `"Domain.ReadModel"` (no `::`): a read model from `READ_MODELS`.
        //   - `{aggregate, field, op, value}`: an ad hoc filter over one aggregate.
        // A question with no generated table row refuses with `TypeMismatch`.
        if let Some(query) = step.get("query") {
            // Read for a future `authorize policy` pass; nothing checks it yet.
            let caller_role = step.get("role").and_then(Json::as_str);
            match query {
                // Entity-query rows are already `{ parent_key => id }.merge(element)`; the
                // reference twin is the same engine.
                // `reference_interpret` delegates to the same `entity_rows`).
                Json::Str(question) if question.contains("::") && named_query::find_entity(ENTITY_QUERIES, question).is_some() => {
                    let def = named_query::find_entity(ENTITY_QUERIES, question).expect("matched by the guard above");
                    match named_query::run_entity(&store, def, args) {
                        Ok(rows) => {
                            let rows = Json::Array(rows);
                            query_results.push(Json::obj(vec![
                                ("query", Json::Str(question.clone())),
                                ("args", args.clone()),
                                ("rows", rows.clone()),
                                ("reference_rows", rows),
                            ]));
                        }
                        Err(refusal) => {
                            let message = refusal.to_string();
                            query_results.push(Json::obj(vec![
                                ("query", Json::Str(question.clone())),
                                ("args", args.clone()),
                                ("rows", Json::Null),
                                ("error", Json::Str(message.clone())),
                                ("reference_rows", Json::Null),
                                ("reference_error", Json::Str(message)),
                            ]));
                            refusals.push((question.clone(), refusal));
                        }
                    }
                }
                Json::Str(question) if question.contains("::") => match named_query::find(QUERIES, question) {
                    Some(def) => match check_query_args(question, args).and_then(|()| named_query::run(&store, def, args, caller_role)) {
                        Ok(entries) => {
                            let rows = Json::Array(entries.into_iter().map(|(id, record)| repository::row_json(id, record)).collect());
                            query_results.push(Json::obj(vec![
                                ("query", Json::Str(question.clone())),
                                ("args", args.clone()),
                                ("rows", rows.clone()),
                                // Same as `rows`: one compiled path (named_query.rs).
                                ("reference_rows", rows),
                            ]));
                        }
                        // A refused query still gets an entry with `rows: null`, as in Ruby; one
                        // compiled path means `error` and `reference_error` are the same string.
                        Err(refusal) => {
                            let message = refusal.to_string();
                            query_results.push(Json::obj(vec![
                                ("query", Json::Str(question.clone())),
                                ("args", args.clone()),
                                ("rows", Json::Null),
                                ("error", Json::Str(message.clone())),
                                ("reference_rows", Json::Null),
                                ("reference_error", Json::Str(message)),
                            ]));
                            refusals.push((question.clone(), refusal));
                        }
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
                                // No `reference_rows` key: Ruby sets it only for questions with a
                                // reference twin, and a read model has none.
                            ]));
                        }
                        // As above, minus the reference keys.
                        Err(refusal) => {
                            let message = refusal.to_string();
                            query_results.push(Json::obj(vec![
                                ("query", Json::Str(question.clone())),
                                ("args", args.clone()),
                                ("rows", Json::Null),
                                ("error", Json::Str(message)),
                            ]));
                            refusals.push((question.clone(), refusal));
                        }
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
            // See `actor_id` on the command step below.
            let caller_actor_id = step.get("actor_id").and_then(Json::as_str);
            let command_input = dry_run_command_input(args);
            dry_runs.push(dry_run(&store, verb, &command_input, caller_role, caller_actor_id));
            mutations_per_step.push(Vec::new());
            cross_domain_per_step.push(Vec::new());
            continue;
        }

        let verb = match step.get("verb").and_then(Json::as_str) {
            Some(v) => v,
            None => return error_output("step missing \"verb\", \"dry_run\", or \"query\""),
        };

        // Per-step `role:` stands in for Ruby's ambient `Hecks.as_caller`; passed to the top-level
        // `orchestrate` call only, never to a reaction's re-entry (as `Dispatcher#reenter`).
        let caller_role = step.get("role").and_then(Json::as_str);

        // Without `actor_id:` the role is checked by string equality against the command's `role`;
        // with it, by a Governance lookup (`check_role_via`). Top-level call only, like `role:`.
        let caller_actor_id = step.get("actor_id").and_then(Json::as_str);

        // Stamped once per step by rust/host, since the kernel has no clock; absent means `None`.
        let occurred_at = step.get("occurred_at").and_then(Json::as_str);

        // Direct callers use top-level `to`/`with`; the durable host wraps them under `args`.
        let command_input = command_input(step, args);

        // `orchestrate` appends every event itself; only the top-level refusal is recorded here.
        // Mutations from a refused command stay recorded: earlier saga legs may have saved.
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
            entity_identity_head_fn: entity_identity_head_for_path,
        };
        if let Err(refusal) = orchestrate(
            &mut store,
            dispatch_by_name,
            tables,
            &mut sagas,
            verb,
            command_input,
            caller_role,
            caller_actor_id,
            None,
            occurred_at,
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
            .map(|(verb, r)| Json::obj(vec![("verb", Json::str(verb.clone())), ("error", Json::str(r.to_string())), ("kind", Json::str(r.kind().to_string()))]))
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
        // Whole-run logs, not per-step.
        ("reactions".to_string(), Json::Array(reaction_log)),
        ("sagas".to_string(), Json::Array(saga_log)),
        // State at the end of the run, fed back as `"sagas"` next time; the `"sagas"` key above
        // is the transition log, including refused transitions.
        ("saga_snapshot".to_string(), saga_snapshot_json(&sagas)),
    ])
    .to_json_string()
}

/// Evaluates a command against a throwaway copy of the store; `"error"` carries the refusal
/// a real dispatch would have raised.
fn dry_run(store: &Store, verb: &str, command_input: &Json, caller_role: Option<&str>, caller_actor_id: Option<&str>) -> Json {
    let mut scratch = store.clone();
    match dispatch_by_name(&mut scratch, verb, command_input, caller_role, caller_actor_id, &mut Vec::new()) {
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
        entity_identity_head_fn: entity_identity_head_for_path,
    }
}

/// `--serve` mode: one JSON step per stdin line, one answer per stdout line, store kept across
/// lines. Beyond `verb` it takes `dry_run`, `snapshot`, `restore` and `instances` steps.
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
                let caller_actor_id = step.get("actor_id").and_then(Json::as_str);
                let occurred_at = step.get("occurred_at").and_then(Json::as_str);
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
                    dry_run(&store, verb, &dry_run_command_input(args), caller_role, caller_actor_id)
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
                        caller_actor_id,
                        None,
                        occurred_at,
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
        .ok_or_else(|| Refusal::Fault(format!("unknown query comparator {op:?}")))?;
    let entries = store
        .scan(aggregate)
        .ok_or_else(|| Refusal::Fault(format!("unknown aggregate {aggregate:?}")))?;

    let matched = repository::filter_entries(entries, field, comparator, value);
    Ok(matched.into_iter().map(|(id, record)| repository::row_json(id, record)).collect())
}

fn required_str<'a>(filter: &'a Json, key: &str) -> Result<&'a str, Refusal> {
    filter
        .require(key, "query filter")?
        .as_str()
        .ok_or_else(|| Refusal::TypeMismatch(format!("query filter {key:?} must be a string")))
}

/// The `refusals` verb column for a refused ad hoc filter, which has no verb; tolerates
/// missing or mistyped fields.
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

// Not `command_input()`: Ruby's `dry_run?` forwards every arg key, `to`/`with` included, as flat
// facts. Wrapping under `with` keeps a fact named `to` from being read as a routing envelope.
fn dry_run_command_input(args: &Json) -> Json {
    Json::obj(vec![("with", args.clone())])
}

fn mutation_to_json(mutation: &MutationRecord) -> Json {
    Json::obj(vec![
        ("aggregate", Json::str(mutation.aggregate.clone())),
        ("id", Json::str(mutation.id.clone())),
        ("operation", Json::str(mutation.operation.to_string())),
        ("state", mutation.state.clone()),
    ])
}

fn cross_domain_reaction_to_json(reaction: &PendingCrossDomainReaction) -> Json {
    Json::obj(vec![
        ("policy", Json::str(reaction.policy_name.clone())),
        // Additive: `lambda_client::deliver` never reads `on`; rust/host uses it to build a
        // reaction_log record.
        ("on", Json::str(reaction.event_name.clone())),
        ("target_domain", Json::str(reaction.target_domain.clone())),
        ("target_verb", Json::str(reaction.target_verb.clone())),
        ("payload", reaction.payload.clone()),
    ])
}

/// The live `sagas` map as a JSON array, in the shape the `"sagas"` input key parses.
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
                    // Round-trips the compensation ledger, as `state`/`memory`.
                    (
                        "completed_compensations",
                        Json::Array(
                            instance
                                .completed_compensations
                                .iter()
                                .map(|entry| {
                                    Json::obj(vec![
                                        ("command_name", Json::str(entry.command_name.clone())),
                                        ("args", entry.args.clone()),
                                    ])
                                })
                                .collect(),
                        ),
                    ),
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
        // Key order matches Ruby's `Event#to_h`; `None` serialises as null.
        ("occurred_at", event.occurred_at.clone().map(Json::Str).unwrap_or(Json::Null)),
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

    // A domain fact named `to` must dry-run as a plain fact, never a routing attempt
    // (pinned end to end by `roster_mark_dry_run_to_collision.json`).
    #[test]
    fn dry_run_command_input_never_sniffs_a_flat_facts_to_key_as_routing() {
        let args = Json::obj(vec![
            ("to", Json::obj(vec![("value", Json::int(570))])),
            ("name", Json::obj(vec![("value", Json::str("crew-1"))])),
        ]);

        let wrapped = dry_run_command_input(&args);
        let invocation = crate::kernel::CommandInvocation::from_json(&wrapped).unwrap();

        assert_eq!(invocation.route(), None);
        assert_eq!(
            invocation.facts().get("to").and_then(|to| to.get("value")).and_then(Json::as_i64),
            Some(570)
        );
        assert_eq!(
            invocation.facts().get("name").and_then(|name| name.get("value")).and_then(Json::as_str),
            Some("crew-1")
        );
    }
}
