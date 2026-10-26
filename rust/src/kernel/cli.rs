//! The stdin/stdout JSON CLI shared by the native binary and the wasm32-wasip1 module.
//! `run` reads `{"steps": [...]}` and hands each step to `kernel::orchestrate` (ADR 0012), or
//! `{"present": answer}` and answers that answer bare (`kernel::present`).

use super::collecting::{self, Collected, Detail};
use super::vocab::RefusalClass;
use super::{
    named_query, orchestrate, query_comparators, read_model, repository, AggregateScan,
    CompletedCompensation, Event, Json, MutationRecord, PendingCrossDomainReaction, Refusal,
    SagaInstance, Tables,
};
use crate::generated::active::{
    command_attributes_for_verb, command_creates, dispatch_by_name, entity_identity_head_for_path,
    identity_head_for_aggregate, reference_key_for_aggregate, Store, CROSS_DOMAIN_POLICIES,
    POLICIES, PROCESS_MANAGERS, QUERIES, READ_MODELS,
};
use std::collections::HashMap;

// Builds and invariant-checks a named query's value-object arguments (ADR 0037).
use crate::generated::active::check_query_args;

use crate::generated::active::ENTITY_QUERIES;

pub fn run(input: &str) -> String {
    let parsed = match Json::parse(input) {
        Ok(v) => v,
        Err(e) => return error_output(&format!("invalid JSON on stdin: {e}")),
    };

    // `{"present": answer}`: a run's answer in the bare shape a caller reads (single-field value
    // objects as their sole field); no step runs, and stored state stays wrapped.
    // Parsed again keeping number text, so a Float the answer carries is written back unchanged.
    if parsed.get("present").is_some() {
        let answer = Json::parse_keeping_number_text(input)
            .ok()
            .and_then(|whole| whole.get("present").cloned())
            .unwrap_or(Json::Null);
        return super::present::present_answer(answer, crate::generated::active::present)
            .to_json_string();
    }

    // Optional `"needs"`: which commands need which outside facts (ADR 0081), passed by the host.
    super::needs::install(parsed.get("needs"));
    // Optional `"query_needs"`: which queries need which outside facts, filled the same way.
    super::needs::install_queries(parsed.get("query_needs"));
    // Optional `"defaults"`: each command's declared argument defaults, filled the same way.
    super::needs::install_defaults(parsed.get("defaults"));

    let Some(steps) = parsed.get("steps").and_then(Json::as_array) else {
        return error_output("expected a top-level {\"steps\": [...]} object");
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
    let mut sagas: HashMap<(String, String), SagaInstance> = parsed
        .get("sagas")
        .and_then(Json::as_array)
        .map_or_else(HashMap::new, |entries| {
            entries
                .iter()
                .filter_map(|entry| {
                    let process_manager = entry.get("process_manager")?.as_str()?.to_string();
                    let correlation = entry.get("correlation")?.as_str()?.to_string();
                    let state = entry.get("state")?.as_str()?.to_string();
                    let memory = entry
                        .get("memory")
                        .cloned()
                        .unwrap_or_else(|| Json::Object(vec![]));
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
                    Some((
                        (process_manager, correlation),
                        SagaInstance {
                            state,
                            memory,
                            completed_compensations,
                        },
                    ))
                })
                .collect()
        });
    // One entry per step, parallel to `steps`, so a host can read `.last()` for the newest step.
    let mut mutations_per_step: Vec<Vec<MutationRecord>> = Vec::new();
    // Parallel to `mutations_per_step`: policies that named a domain not compiled into this
    // `Store`; rust/host delivers them.
    let mut cross_domain_per_step: Vec<Vec<PendingCrossDomainReaction>> = Vec::new();
    // Parallel to `mutations_per_step`: the slice of `reaction_log` each step appended, so a
    // host reads `.last()` for only the newest step's reactions, not the replayed history's.
    let mut reactions_per_step: Vec<Json> = Vec::new();
    // Whole-run accumulations matching `Registry#reaction_log`/`#saga_log`; never reset per step.
    let mut reaction_log: Vec<Json> = Vec::new();
    let mut saga_log: Vec<Json> = Vec::new();
    // One entry per answered `query` step; a refused query goes to `refusals` instead.
    let mut query_results: Vec<Json> = Vec::new();
    // One entry per `dry_run` step: the command run against a throwaway clone of the store.
    let mut dry_runs: Vec<Json> = Vec::new();
    // One entry per `validate` step: every refusal a command would meet, as data.
    let mut validations: Vec<Json> = Vec::new();

    for step in steps {
        // A query step's `args` sit at the sibling `"args"` key, as for a command step.
        let empty_args = Json::Object(vec![]);
        let args = step.get("args").unwrap_or(&empty_args);
        // What the caller offered is what the log echoes; a fact the query `needs` is answered
        // for the run alone (ADR 0081), so the log holds no value that depends on the clock.
        let offered = args;
        let filled = match step.get("query") {
            Some(Json::Str(question)) => super::needs::enrich_query(
                question,
                args,
                step.get("occurred_at").and_then(Json::as_str),
            ),
            _ => None,
        };
        let args = filled.as_ref().unwrap_or(args);

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
                    // reason: the match guard above only admits a `question` that resolves.
                    #[allow(clippy::expect_used)]
                    let def = named_query::find_entity(ENTITY_QUERIES, question).expect("matched by the guard above");
                    match named_query::run_entity(&store, def, args) {
                        Ok(rows) => {
                            query_results.push(answered_entry(question, offered, Json::Array(rows), true));
                        }
                        Err(refusal) => {
                            query_results.push(refused_entry(question, offered, &refusal, true));
                            refusals.push((question.clone(), refusal));
                        }
                    }
                }
                Json::Str(question) if question.contains("::") => match named_query::find(QUERIES, question) {
                    Some(def) => match check_query_args(question, args).and_then(|()| named_query::run(&store, def, args, caller_role)) {
                        Ok(entries) => {
                            let rows = Json::Array(entries.into_iter().map(|(id, record)| repository::row_json(id, record)).collect());
                            // The reference twin is `rows`: one compiled path (named_query.rs).
                            query_results.push(answered_entry(question, offered, rows, true));
                        }
                        // A refused query still gets an entry with `rows: null`, as in Ruby; one
                        // compiled path means `error` and `reference_error` are the same string.
                        Err(refusal) => {
                            query_results.push(refused_entry(question, offered, &refusal, true));
                            refusals.push((question.clone(), refusal));
                        }
                    },
                    // Only a query the generator did not emit reaches here; the codegen manifest lists
                    // each one it skipped, with the reason.
                    None => refusals.push((
                        question.clone(),
                        Refusal::TypeMismatch(format!(
                            "named/declared query {question:?} is not generated for this domain — either unknown, or a \
                             real declared query whose shape this generator's codegen doesn't cover yet (cursor/\
                             consistency/freshness/inspection/index_hints, a where clause on a field the aggregate \
                             does not declare, or a literal comparator value whose true JSON type can't be \
                             recovered from the exported IR — hecks-codegen's manifest names which); a declared \
                             query with or without a where, ordered and bounded as declared, and the ad hoc \
                             filter shape ({{\"aggregate\",\"field\",\"op\",\"value\"}}) both execute for real"
                        )),
                    )),
                },
                Json::Str(question) => match read_model::find(READ_MODELS, question) {
                    Some(def) => match read_model::run(&store, def, args) {
                        // No reference keys: Ruby sets them only for questions with a reference twin,
                        // and a read model has none.
                        Ok(row) => query_results.push(answered_entry(question, offered, Json::Array(vec![row]), false)),
                        Err(refusal) => {
                            query_results.push(refused_entry(question, offered, &refusal, false));
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
                             nulls/inspect_query/use_index — rust/codegen/src/read_models.rs's own header has the full \
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
            reactions_per_step.push(Json::Array(Vec::new()));
            continue;
        }

        if let Some(verb) = step.get("dry_run").and_then(Json::as_str) {
            let caller_role = step.get("role").and_then(Json::as_str);
            // See `actor_id` on the command step below.
            let caller_actor_id = step.get("actor_id").and_then(Json::as_str);
            let command_input = dry_run_input(step, args);
            dry_runs.push(dry_run(
                &store,
                verb,
                &command_input,
                caller_role,
                caller_actor_id,
            ));
            mutations_per_step.push(Vec::new());
            cross_domain_per_step.push(Vec::new());
            reactions_per_step.push(Json::Array(Vec::new()));
            continue;
        }

        if let Some(verb) = step.get("validate").and_then(Json::as_str) {
            let caller_role = step.get("role").and_then(Json::as_str);
            let caller_actor_id = step.get("actor_id").and_then(Json::as_str);
            let command_input = dry_run_input(step, args);
            validations.push(validation(
                &store,
                verb,
                &command_input,
                caller_role,
                caller_actor_id,
            ));
            mutations_per_step.push(Vec::new());
            cross_domain_per_step.push(Vec::new());
            reactions_per_step.push(Json::Array(Vec::new()));
            continue;
        }

        let Some(verb) = step.get("verb").and_then(Json::as_str) else {
            return error_output("step missing \"verb\", \"dry_run\", \"validate\", or \"query\"");
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
        let reactions_before = reaction_log.len();
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
        reactions_per_step.push(Json::Array(reaction_log[reactions_before..].to_vec()));
    }

    let events_json = Json::Array(events.iter().map(event_to_json).collect());
    let refusals_json = Json::Array(
        refusals
            .iter()
            .map(|(verb, r)| {
                Json::obj(vec![
                    ("verb", Json::str(verb.clone())),
                    ("error", Json::str(r.to_string())),
                    ("kind", Json::str(r.kind().to_string())),
                ])
            })
            .collect(),
    );
    let mutations_json = Json::Array(
        mutations_per_step
            .iter()
            .map(|step_mutations| {
                Json::Array(step_mutations.iter().map(mutation_to_json).collect())
            })
            .collect(),
    );
    let cross_domain_json = Json::Array(
        cross_domain_per_step
            .iter()
            .map(|step_reactions| {
                Json::Array(
                    step_reactions
                        .iter()
                        .map(cross_domain_reaction_to_json)
                        .collect(),
                )
            })
            .collect(),
    );

    Json::Object(vec![
        ("instances".to_string(), Json::Object(store.instances())),
        ("events".to_string(), events_json),
        ("refusals".to_string(), refusals_json),
        ("dry_runs".to_string(), Json::Array(dry_runs)),
        ("validations".to_string(), Json::Array(validations)),
        ("mutations".to_string(), mutations_json),
        ("queries".to_string(), Json::Array(query_results)),
        ("cross_domain_reactions".to_string(), cross_domain_json),
        // Whole-run logs, not per-step.
        ("reactions".to_string(), Json::Array(reaction_log)),
        (
            "reactions_per_step".to_string(),
            Json::Array(reactions_per_step),
        ),
        ("sagas".to_string(), Json::Array(saga_log)),
        // State at the end of the run, fed back as `"sagas"` next time; the `"sagas"` key above
        // is the transition log, including refused transitions.
        ("saga_snapshot".to_string(), saga_snapshot_json(&sagas)),
    ])
    .to_json_string()
}

/// Evaluates a command against a throwaway copy of the store; `"error"` carries the refusal
/// a real dispatch would have raised.
fn dry_run(
    store: &Store,
    verb: &str,
    command_input: &Json,
    caller_role: Option<&str>,
    caller_actor_id: Option<&str>,
) -> Json {
    let (outcome, collected) = preview(store, verb, command_input, caller_role, caller_actor_id);
    match outcome {
        Ok(()) => Json::obj(vec![
            ("verb", Json::str(verb.to_string())),
            ("ok", Json::Bool(true)),
        ]),
        Err(refusal) => refused_dry_run(verb, &refusal, &collected),
    }
}

/// Every reason a command would be refused, as data: `{verb, ok, refusals}` with each refusal's
/// class, kind, stage, attribute, path, rule and message. The step `validate` answers with.
fn validation(
    store: &Store,
    verb: &str,
    command_input: &Json,
    caller_role: Option<&str>,
    caller_actor_id: Option<&str>,
) -> Json {
    let (outcome, collected) = preview(store, verb, command_input, caller_role, caller_actor_id);
    let refusals: Vec<Json> = match outcome {
        Ok(()) => Vec::new(),
        Err(refusal) if collected.is_empty() => vec![refusal_entry(&refusal, &Detail::default())],
        Err(_) => collected
            .iter()
            .map(|kept| refusal_entry(&kept.refusal, &kept.detail))
            .collect(),
    };
    Json::obj(vec![
        ("verb", Json::str(verb.to_string())),
        ("ok", Json::Bool(refusals.is_empty())),
        ("refusals", Json::Array(refusals)),
    ])
}

/// The command run against a throwaway copy of the store with a collector bound: what it raised,
/// and every refusal its failing stage kept.
fn preview(
    store: &Store,
    verb: &str,
    command_input: &Json,
    caller_role: Option<&str>,
    caller_actor_id: Option<&str>,
) -> (Result<(), Refusal>, Vec<Collected>) {
    let mut scratch = store.clone();
    let (outcome, collected) = collecting::collecting(|| {
        dispatch_by_name(
            &mut scratch,
            verb,
            command_input,
            caller_role,
            caller_actor_id,
            &mut Vec::new(),
        )
    });
    (outcome.map(|_| ()), collected)
}

/// A refused dry run: the refusal's text, its class name, and the `kind` and `stage` the language's
/// `RefusalClass` table gives that class. A refusal the table does not class (`Fault`) is a plain
/// refusal in the `state` stage, as `Hecks::Refused` classes one in Ruby.
///
/// `reasons` holds every refusal the failing stage collected; `refusals` lists them all, or just
/// `refusal` when the stage raised without collecting (a role, argument or lifecycle refusal).
fn refused_dry_run(verb: &str, refusal: &Refusal, reasons: &[Collected]) -> Json {
    let all: Vec<Json> = if reasons.is_empty() {
        vec![refusal_entry(refusal, &Detail::default())]
    } else {
        reasons
            .iter()
            .map(|kept| refusal_entry(&kept.refusal, &kept.detail))
            .collect()
    };
    let (kind, stage) = refusal_class(refusal);
    Json::obj(vec![
        ("verb", Json::str(verb.to_string())),
        ("ok", Json::Bool(false)),
        ("error", Json::str(refusal.to_string())),
        ("refusal", Json::str(refusal.kind().to_string())),
        ("kind", Json::str(kind.to_string())),
        ("stage", Json::str(stage.to_string())),
        ("refusals", Json::Array(all)),
    ])
}

fn refusal_class(refusal: &Refusal) -> (&'static str, &'static str) {
    RefusalClass::from_name(refusal.kind())
        .map_or(("refused", "state"), |class| (class.kind(), class.stage()))
}

/// One refusal as a client reads it: the class, kind and stage, the message, and what it is about
/// (`attribute` and `path` for an argument, `rule` for a given, ensure or invariant), null otherwise.
fn refusal_entry(refusal: &Refusal, detail: &Detail) -> Json {
    let (kind, stage) = refusal_class(refusal);
    let text = |value: &Option<String>| value.clone().map_or(Json::Null, Json::Str);
    Json::obj(vec![
        ("kind", Json::str(kind.to_string())),
        ("stage", Json::str(stage.to_string())),
        ("refusal", Json::str(refusal.kind().to_string())),
        ("attribute", text(&detail.attribute)),
        ("path", text(&detail.path)),
        ("rule", text(&detail.rule)),
        ("message", Json::str(refusal.to_string())),
    ])
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

/// Saga instances by (saga, correlation id), as `serve` keeps them across steps.
type SagaMap = HashMap<(String, String), SagaInstance>;

/// `--serve` mode: one JSON step per stdin line, one answer per stdout line, store kept across
/// lines. Beyond `verb` it takes `dry_run`, `snapshot`, `restore` and `instances` steps.
pub fn serve(input: impl std::io::BufRead, mut output: impl std::io::Write) {
    let mut store = Store::new();
    let mut sagas = SagaMap::new();
    let mut reaction_log: Vec<Json> = Vec::new();
    let mut saga_log: Vec<Json> = Vec::new();
    let mut snapshot: Option<(Store, SagaMap)> = None;
    let ok = || Json::obj(vec![("ok", Json::Bool(true))]);

    for line in input.lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let answer = match Json::parse(&line) {
            Err(e) => Json::obj(vec![
                ("ok", Json::Bool(false)),
                ("error", Json::str(format!("invalid JSON: {e}"))),
            ]),
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
                            sagas.clone_from(g);
                            ok()
                        }
                        None => Json::obj(vec![
                            ("ok", Json::Bool(false)),
                            ("error", Json::str("no snapshot to restore")),
                        ]),
                    }
                } else if step.get("instances").is_some() {
                    Json::obj(vec![
                        ("ok", Json::Bool(true)),
                        ("instances", Json::Object(store.instances())),
                    ])
                } else if let Some(verb) = step.get("dry_run").and_then(Json::as_str) {
                    dry_run(
                        &store,
                        verb,
                        &dry_run_command_input(args),
                        caller_role,
                        caller_actor_id,
                    )
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
                        Ok(()) => Json::obj(vec![
                            ("ok", Json::Bool(true)),
                            (
                                "events",
                                Json::Array(events.iter().map(event_to_json).collect()),
                            ),
                        ]),
                        Err(refusal) => Json::obj(vec![
                            ("ok", Json::Bool(false)),
                            ("error", Json::str(refusal.to_string())),
                        ]),
                    }
                } else {
                    Json::obj(vec![
                        ("ok", Json::Bool(false)),
                        (
                            "error",
                            Json::str("step needs verb, dry_run, snapshot, restore, or instances"),
                        ),
                    ])
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
    Ok(matched
        .into_iter()
        .map(|(id, record)| repository::row_json(id, record))
        .collect())
}

fn required_str<'a>(filter: &'a Json, key: &str) -> Result<&'a str, Refusal> {
    filter
        .require(key, "query filter")?
        .as_str()
        .ok_or_else(|| Refusal::TypeMismatch(format!("query filter {key:?} must be a string")))
}

/// The `refusals` verb column for a refused ad hoc filter, which has no verb; tolerates
/// missing or mistyped fields.
/// The log entry for an answered `query` step. A question with a reference twin also carries
/// `reference_rows`, the same rows because both come from one compiled path.
fn answered_entry(question: &str, offered: &Json, rows: Json, with_reference: bool) -> Json {
    let mut fields = vec![
        ("query", Json::Str(question.to_string())),
        ("args", offered.clone()),
        ("rows", rows.clone()),
    ];
    if with_reference {
        fields.push(("reference_rows", rows));
    }
    Json::obj(fields)
}

/// The log entry for a refused `query` step: `rows: null` and the refusal's text, with the
/// reference twin's null rows and identical error when the question has one.
fn refused_entry(question: &str, offered: &Json, refusal: &Refusal, with_reference: bool) -> Json {
    let message = refusal.to_string();
    let mut fields = vec![
        ("query", Json::Str(question.to_string())),
        ("args", offered.clone()),
        ("rows", Json::Null),
        ("error", Json::Str(message.clone())),
    ];
    if with_reference {
        fields.push(("reference_rows", Json::Null));
        fields.push(("reference_error", Json::Str(message)));
    }
    Json::obj(fields)
}

fn filter_label(filter: &Json) -> String {
    let field = |key: &str| filter.get(key).and_then(Json::as_str).unwrap_or("");
    format!(
        "filter {}.{} {}",
        field("aggregate"),
        field("field"),
        field("op")
    )
}

fn command_input<'a>(step: &'a Json, legacy_args: &'a Json) -> &'a Json {
    if step.get("to").is_some() || step.get("with").is_some() {
        step
    } else {
        legacy_args
    }
}

// A dry run that names its receiver, with top-level `to`/`with` as a real step does (the host
// previews this way), is routed as that step would be. Otherwise `args` are flat facts.
fn dry_run_input(step: &Json, args: &Json) -> Json {
    if step.get("to").is_some() || step.get("with").is_some() {
        step.clone()
    } else {
        dry_run_command_input(args)
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
///
/// In key order: a `HashMap` iterates in an order seeded per process, so the same run would answer
/// differently each time and two stores fed the same sagas would disagree on order alone.
fn saga_snapshot_json(sagas: &HashMap<(String, String), SagaInstance>) -> Json {
    let mut keyed: Vec<_> = sagas.iter().collect();
    keyed.sort_by(|a, b| a.0.cmp(b.0));
    Json::Array(
        keyed
            .into_iter()
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
        (
            "occurred_at",
            event.occurred_at.clone().map_or(Json::Null, Json::Str),
        ),
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
        assert_eq!(
            invocation.facts().get("branch_code").and_then(Json::as_str),
            Some("DOWNTOWN")
        );
        assert_eq!(
            invocation.facts().get("box_number").and_then(Json::as_i64),
            Some(12)
        );
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
            invocation
                .facts()
                .get("to")
                .and_then(|to| to.get("value"))
                .and_then(Json::as_i64),
            Some(570)
        );
        assert_eq!(
            invocation
                .facts()
                .get("name")
                .and_then(|name| name.get("value"))
                .and_then(Json::as_str),
            Some("crew-1")
        );
    }
}

#[cfg(test)]
mod refused_dry_run_tests {
    use super::*;

    fn answer(refusal: &Refusal) -> String {
        refused_dry_run("A::B.C", refusal, &[]).to_json_string()
    }

    #[test]
    fn a_stage_that_collected_lists_every_refusal_and_one_that_did_not_lists_its_own() {
        let first = Refusal::GivenNotMet("C refused — one".to_string());
        let second = Refusal::GivenNotMet("C refused — two".to_string());

        let kept = |refusal: Refusal, rule: &str| Collected {
            refusal,
            detail: Detail::rule(rule),
        };
        let collected = refused_dry_run(
            "A::B.C",
            &first,
            &[kept(first.clone(), "one"), kept(second, "two")],
        )
        .to_json_string();
        let alone = answer(&first);
        assert!(
            collected.contains(r#""rule":"one""#) && collected.contains(r#""rule":"two""#),
            "{collected}"
        );
        assert!(alone.contains(r#""rule":null"#), "{alone}");

        assert!(
            collected.contains("C refused — one") && collected.contains("C refused — two"),
            "{collected}"
        );
        assert_eq!(
            alone.matches(r#""refusal":"GivenNotMet""#).count(),
            2,
            "{alone}"
        );
        assert!(!alone.contains("two"), "{alone}");
    }

    #[test]
    fn a_refused_dry_run_names_the_class_kind_and_stage_the_language_gives_it() {
        let json = answer(&Refusal::GivenNotMet(
            "C refused — the balance is zero".to_string(),
        ));
        assert!(json.contains(r#""ok":false"#), "{json}");
        assert!(json.contains(r#""refusal":"GivenNotMet""#), "{json}");
        assert!(json.contains(r#""kind":"refused""#), "{json}");
        assert!(json.contains(r#""stage":"givens""#), "{json}");
    }

    #[test]
    fn a_missing_record_is_kind_not_found() {
        let json = answer(&Refusal::NotFound("no Account a1".to_string()));
        assert!(json.contains(r#""kind":"not_found""#), "{json}");
    }

    #[test]
    fn a_role_the_caller_lacks_is_kind_unauthorized_in_the_role_stage() {
        let json = answer(&Refusal::Unauthorized("role".to_string()));
        assert!(
            json.contains(r#""kind":"unauthorized""#) && json.contains(r#""stage":"role""#),
            "{json}"
        );
    }

    #[test]
    fn a_refusal_the_language_does_not_class_is_a_plain_refusal_in_the_state_stage() {
        let json = answer(&Refusal::Fault("boom".to_string()));
        assert!(
            json.contains(r#""kind":"refused""#) && json.contains(r#""stage":"state""#),
            "{json}"
        );
    }
}
