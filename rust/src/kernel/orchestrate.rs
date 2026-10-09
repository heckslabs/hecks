//! Reactions to dispatched events: policy matching and process-manager advancement, recursive
//! and bounded by `MAX_REACTION_DEPTH`. Cross-domain matches are returned for the host to deliver.

use super::expr::{interpret, EvalContext, Expr, NoFields};
use super::named_query;
use super::repository::AggregateScan;
use super::{Event, Json, MutationRecord, Refusal};
use std::collections::HashMap;

pub const MAX_REACTION_DEPTH: usize = 5;

/// One `policy` block whose target lives in this domain.
pub struct PolicyRule {
    pub policy_name: &'static str,
    pub event_name: &'static str,
    pub event_qualifier: Option<&'static str>,
    pub target_verb: &'static str,
    /// `where { ... }` predicate. A function because an `Expr` owns boxes and cannot sit in a
    /// const table.
    pub where_expr: Option<fn() -> Expr>,
    /// Domain-qualified query verb a fan-out runs, settled at codegen.
    pub for_each: Option<&'static str>,
    /// Name each matched row's ID is minted under, resolved at codegen from the target command.
    /// The target command, not the aggregate name, decides it (`account` vs `account_id`).
    pub for_each_key: Option<&'static str>,
    /// `trigger ..., with:` as `(argument_name, binding)` pairs; empty forwards the whole payload.
    /// A binding starting with ":" names a source field; any other is a rendered literal.
    pub with_spec: &'static [(&'static str, &'static str)],
}

/// A policy block with `across "OtherDomain"`: matched here, delivered by the host.
pub struct CrossDomainPolicyRule {
    pub policy_name: &'static str,
    pub event_name: &'static str,
    pub event_qualifier: Option<&'static str>,
    pub where_expr: Option<fn() -> Expr>,
    pub target_domain: &'static str,
    pub target_verb: &'static str,
}

/// A matched cross-domain reaction the host must deliver; the payload is forwarded unchanged.
#[derive(Clone)]
pub struct PendingCrossDomainReaction {
    pub policy_name: String,
    pub event_name: String,
    pub target_domain: String,
    pub target_verb: String,
    pub payload: Json,
}

/// A `with:` binding value. `Literal` is a function because `Json` cannot be built in a const
/// table.
pub enum WithValue {
    Ref(&'static str),
    Literal(fn() -> Json),
}

pub struct DispatchSpec {
    pub command_name: &'static str,
    pub with: &'static [(&'static str, WithValue)],
    /// The command that undoes this dispatch, if any. A reference so the const table can nest it;
    /// a compensation is never itself compensable.
    pub compensates: Option<&'static DispatchSpec>,
}

/// One leg of a process manager: on `event_type` from `from_state`, move to `to_state` and
/// dispatch.
pub struct Handler {
    pub event_type: &'static str,
    pub from_state: &'static str,
    pub to_state: &'static str,
    pub dispatches: &'static [DispatchSpec],
}

/// One `process_manager` block; `initial_state` is the first declared state.
pub struct ProcessManagerDef {
    pub name: &'static str,
    pub correlates_by: &'static str,
    pub starts_on: &'static str,
    pub ends_on: &'static str,
    pub initial_state: &'static str,
    pub handlers: &'static [Handler],
}

/// Event type a compensating leg (`on :refused`) is declared under.
pub const REFUSED: &str = "refused";

/// A live process-manager instance, keyed `(process_manager_name, correlation)` by its owner.
#[derive(Clone)]
pub struct SagaInstance {
    pub state: String,
    pub memory: Json,
    /// Compensations of completed dispatches, oldest first so `pop` drains newest-first.
    /// Recorded before the forward dispatch runs (see `deliver_saga_dispatch`).
    pub completed_compensations: Vec<CompletedCompensation>,
}

/// A compensation ledger entry; `args` are resolved when the entry is pushed.
/// Owned strings, because it round-trips through the saga snapshot JSON.
#[derive(Clone)]
pub struct CompletedCompensation {
    pub command_name: String,
    pub args: Json,
}

// Build refuses two legs on one (event, state) pair, so the first match is the only one.
fn select_leg<'a>(pm: &'a ProcessManagerDef, event: &str, state: &str) -> Option<&'a Handler> {
    pm.handlers.iter().find(|h| h.event_type == event && h.from_state == state)
}

fn leg_mismatch(pm: &ProcessManagerDef, event: &str, state: &str) -> String {
    let mut expected: Vec<String> = Vec::new();
    for h in pm.handlers.iter().filter(|h| h.event_type == event) {
        let spelled = format!("{:?}", h.from_state);
        if !expected.contains(&spelled) {
            expected.push(spelled);
        }
    }
    format!("in {state:?}, not {}", expected.join(" or "))
}

fn correlation_head(correlates_by: &str) -> &str {
    correlates_by.split('.').next().unwrap_or(correlates_by)
}

// An empty correlation counts as absent, so callers need only one check.
fn correlation_of(pm: &ProcessManagerDef, event: &Event, reference_key_fn: fn(&str) -> Option<&'static str>) -> Option<String> {
    // Tier 1: a dotted path into the event's payload.
    if let Some(v) = event.payload.dig(pm.correlates_by) {
        if let Ok(id) = v.to_id_component() {
            if !id.is_empty() {
                return Some(id);
            }
        }
    }

    // Tier 2: the correlation an earlier saga-leg dispatch stamped on the event.
    if let Some(stamp) = &event.correlation {
        if let Some(v) = stamp.get(correlation_head(pm.correlates_by)) {
            if !v.is_empty() {
                return Some(v.clone());
            }
        }
    }

    // Tier 3: the aggregate's reference key, for a leg dispatched through `reference_to`.
    let key = reference_key_fn(&event.aggregate)?;
    let id = event.payload.get(key)?.to_id_component().ok()?;
    if id.is_empty() {
        None
    } else {
        Some(id)
    }
}

fn resolve_with(pm: &ProcessManagerDef, value: &WithValue, event: &Event, correlation: &str, memory: &Json) -> Json {
    match value {
        WithValue::Literal(build) => build(),
        WithValue::Ref(name) => {
            let head = correlation_head(pm.correlates_by);
            if *name == head {
                Json::Str(correlation.to_string())
            } else if let Some(v) = event.payload.get(name) {
                v.clone()
            } else if let Some(v) = memory.get(name) {
                v.clone()
            } else {
                Json::Null
            }
        }
    }
}

// Always domain-qualifies, and folds the entity-nesting `::` to `.`: generated dispatch arms are
// dot-joined past the aggregate ("Waybill::Manifest.Slot.Fill"). Guessing from a leftover `::`
// cannot tell a cross-domain command from a nested entity's.
fn qualify_saga_command_name(domain_name: &str, command_name: &str) -> String {
    format!("{domain_name}::{}", command_name.replacen("::", ".", 1))
}

fn build_dispatch_args(pm: &ProcessManagerDef, spec: &DispatchSpec, event: &Event, correlation: &str, memory: &Json, domain_name: &str, tables: &Tables) -> Json {
    let projected = Json::Object(spec.with.iter().map(|(key, value)| (key.to_string(), resolve_with(pm, value, event, correlation, memory))).collect());
    // A saga leg's `with:` is always an explicit projection. The verb is qualified before the
    // lookup because the tables are keyed by the qualified verb.
    let qualified = qualify_saga_command_name(domain_name, spec.command_name);
    route_dispatch_args(projected, &qualified, tables, event)
}

#[derive(Clone, Copy)]
pub struct Tables<'a> {
    pub policies: &'a [PolicyRule],
    pub cross_domain_policies: &'a [CrossDomainPolicyRule],
    pub process_managers: &'a [ProcessManagerDef],
    pub reference_key_fn: fn(&str) -> Option<&'static str>,
    pub queries: &'a [crate::kernel::QueryDef],
    pub command_creates_fn: fn(&str) -> bool,
    pub identity_head_fn: fn(&str) -> Option<&'static str>,
    // Slices a reaction's `with:` facts to the target command's declared attributes.
    pub command_attributes_fn: fn(&str) -> &'static [&'static str],
    // Keyed by "Domain::Aggregate.Entity".
    pub entity_identity_head_fn: fn(&str) -> Option<&'static str>,
}

/// Dispatches `verb`, then recursively runs the policies and saga legs its events trigger.
/// Only a refusal of the top-level `verb` is returned; reaction refusals are logged and swallowed.
///
/// `saga_correlation` stamps every event this call produces; only saga-leg dispatches pass it.
#[allow(clippy::too_many_arguments)]
pub fn orchestrate<S: AggregateScan>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>, Option<&str>, &mut Vec<MutationRecord>) -> Result<Vec<Event>, Refusal>,
    tables: Tables<'static>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    verb: &str,
    args: &Json,
    caller_role: Option<&str>,
    // Outermost dispatch only, like `caller_role`: reactions are system-triggered and pass `None`.
    caller_actor_id: Option<&str>,
    saga_correlation: Option<&HashMap<String, String>>,
    // Threaded unchanged into every recursion: one host-supplied moment for the whole cascade.
    occurred_at: Option<&str>,
    depth: usize,
    all_events: &mut Vec<Event>,
    mutations: &mut Vec<MutationRecord>,
    cross_domain: &mut Vec<PendingCrossDomainReaction>,
    reaction_log: &mut Vec<Json>,
    saga_log: &mut Vec<Json>,
) -> Result<(), Refusal> {
    // A fact the command `needs` is answered ahead of every gate (ADR 0081), for a reaction's
    // dispatch as for the outermost one.
    let enriched = super::needs::enrich(verb, args, occurred_at);
    let args = enriched.as_ref().unwrap_or(args);
    let mut events = dispatch_fn(store, verb, args, caller_role, caller_actor_id, mutations)?;

    if let Some(stamp) = saga_correlation {
        for event in &mut events {
            event.correlation.get_or_insert_with(HashMap::new).extend(stamp.iter().map(|(k, v)| (k.clone(), v.clone())));
        }
    }

    if let Some(ts) = occurred_at {
        for event in &mut events {
            event.occurred_at = Some(ts.to_string());
        }
    }

    // Log the whole batch before any reaction runs, so a later event never logs after an
    // earlier event's reactions.
    for event in &events {
        all_events.push(event.clone());
    }

    // Then per event in `emits` order: its policies, then its sagas.
    for event in events {
        // Saga begin/advance/end run for every event regardless of depth; only the re-entry is
        // depth-gated, inside `react_policies` and `deliver_saga_dispatch`.
        react_policies(store, dispatch_fn, tables, sagas, &event, occurred_at, depth, all_events, mutations, cross_domain, reaction_log, saga_log);
        begin_saga(tables, sagas, &event, saga_log);
        advance_saga(store, dispatch_fn, tables, sagas, &event, occurred_at, depth, all_events, mutations, cross_domain, reaction_log, saga_log);
        end_saga(tables, sagas, &event, saga_log);
    }

    Ok(())
}

// Decodes a rendered `with:` literal. Wire text keeps its quote marks, so passing it through
// verbatim would hand a quoted string to `from_json` and the trigger would never fire.
fn read_literal_wire(binding: &str) -> Json {
    if binding == "nil" {
        return Json::Null;
    }
    if binding == "true" {
        return Json::Bool(true);
    }
    if binding == "false" {
        return Json::Bool(false);
    }
    if let Ok(i) = binding.parse::<i64>() {
        return Json::int(i);
    }
    if let Ok(f) = binding.parse::<f64>() {
        return Json::Float(f);
    }
    if binding.len() >= 2 && binding.starts_with('"') && binding.ends_with('"') {
        let inner = &binding[1..binding.len() - 1];
        let mut unescaped = String::with_capacity(inner.len());
        let mut chars = inner.chars();
        while let Some(c) = chars.next() {
            if c == '\\' {
                if let Some(next) = chars.next() {
                    unescaped.push(next);
                    continue;
                }
            }
            unescaped.push(c);
        }
        return Json::str(unescaped);
    }
    // A bare word `Literal.read` also tolerates (its own comment: "a
    // closed set's members and a few hand-written fields... never
    // rendered") — passed through as-is, matching that same tolerance.
    Json::str(binding.to_string())
}

// Adds a fan-out row's fields to a projection's source where the payload and emitter identity have
// not already named them, plus the row's `id` as Ruby's row hash carries it.
fn offer_row_fields(source: &mut Vec<(String, Json)>, row_id: &str, record: &Json) {
    let mut fields: Vec<(String, Json)> = match record {
        Json::Object(pairs) => pairs.clone(),
        _ => Vec::new(),
    };
    if !fields.iter().any(|(name, _)| name == "id") {
        fields.push(("id".to_string(), Json::str(row_id.to_string())));
    }
    for (name, value) in fields {
        if !source.iter().any(|(held, _)| *held == name) {
            source.push((name, value));
        }
    }
}

fn where_holds(where_expr: Option<fn() -> Expr>, event: &Event) -> bool {
    let Some(build) = where_expr else { return true };
    let ctx = EvalContext { args: &event.payload, instance: &NoFields };
    matches!(interpret(&build(), &ctx), Ok(v) if v.truthy())
}

// An empty `with_spec` forwards the whole payload. `extra` (a fan-out's row key) is merged into
// the source before projection, not onto its result.
fn trigger_args(policy: &PolicyRule, event: &Event, extra: Option<(&str, String)>, target_verb: &str, tables: &Tables) -> Json {
    trigger_args_with_row(policy, event, extra, None, target_verb, tables)
}

// `row` is a fan-out's own row (its id and stored record). A projection may read its fields, below
// the emitter identity and the payload; an undeclared projection never sees them.
fn trigger_args_with_row(
    policy: &PolicyRule, event: &Event, extra: Option<(&str, String)>, row: Option<(&str, &Json)>, target_verb: &str, tables: &Tables,
) -> Json {
    let mut source: Vec<(String, Json)> = match &event.payload {
        Json::Object(pairs) => pairs.clone(),
        _ => Vec::new(),
    };
    if let Some((key, id)) = &extra {
        source.retain(|(name, _)| name != key);
        source.push(((*key).to_string(), Json::str(id.clone())));
    }

    if policy.with_spec.is_empty() {
        // No `with:`: lift the same-aggregate event id into the receiver of a non-creating
        // target, as `ReactionInvocation.build` does. Never for a `for_each` row, whose id is
        // already in `source` under the fan-out's own name.
        if extra.is_none() && !(tables.command_creates_fn)(target_verb) {
            if let Some(aggregate_name) = target_verb.rsplit_once('.').map(|(agg, _)| agg) {
                if aggregate_name == event.aggregate {
                    // The lifted receiver replaces any `to` the payload carried; that fact never
                    // reaches the target.
                    source.retain(|(name, _)| name != "to");
                    return Json::obj(vec![("to", Json::str(event.id.clone())), ("with", Json::Object(source))]);
                }
            }
        }
        return Json::Object(source);
    }

    // An explicit projection may read the emitting record's identity, offered under the
    // aggregate's identity head unless the payload already carries it.
    if let Some(head) = (tables.identity_head_fn)(&event.aggregate) {
        if !event.id.is_empty() && !source.iter().any(|(name, _)| name == head) {
            source.push((head.to_string(), Json::str(event.id.clone())));
        }
    }

    if let Some((row_id, record)) = row {
        offer_row_fields(&mut source, row_id, record);
    }

    let projected = policy
        .with_spec
        .iter()
        .map(|(name, binding)| {
            let value = match binding.strip_prefix(':') {
                Some(field) => source
                    .iter()
                    .find(|(held, _)| held == field)
                    .map(|(_, held)| held.clone())
                    .unwrap_or(Json::Null),
                None => read_literal_wire(binding),
            };
            ((*name).to_string(), value)
        })
        .collect();
    // Only an explicit `with:` is split; an undeclared projection forwards the payload unsplit.
    let routed = split_routed_args(Json::Object(projected), target_verb, tables);
    // Fallback when nothing named the target's identity: the source's own is the receiver for a
    // non-creating target on the same aggregate. Projected facts, even a `to`, stay facts.
    if extra.is_none() && !(tables.command_creates_fn)(target_verb) {
        if let Json::Object(pairs) = &routed {
            let already_routed = pairs.iter().any(|(k, _)| k == "to") && pairs.iter().any(|(k, _)| k == "with");
            if !already_routed {
                if let Some(aggregate_name) = target_verb.rsplit_once('.').map(|(agg, _)| agg) {
                    if aggregate_name == event.aggregate {
                        return Json::obj(vec![("to", Json::str(event.id.clone())), ("with", routed)]);
                    }
                }
            }
        }
    }
    routed
}

// Splits resolved args into `{to:, with:}` for a non-creating target with a single-component
// identity. Composite identities and targets the tables know nothing about stay flat: unknown
// means don't route. `facts` slices the original pairs to the command's declared attributes.
fn split_routed_args(projected: Json, target_verb: &str, tables: &Tables) -> Json {
    let Json::Object(pairs) = projected else { return projected };
    let declared = (tables.command_attributes_fn)(target_verb);
    let facts: Vec<(String, Json)> = pairs.iter().filter(|(k, _)| declared.contains(&k.as_str())).cloned().collect();

    if (tables.command_creates_fn)(target_verb) {
        return Json::Object(facts);
    }

    let Some(aggregate_name) = target_verb.rsplit_once('.').map(|(agg, _)| agg) else {
        return Json::Object(facts);
    };

    let candidates = [(tables.identity_head_fn)(aggregate_name), (tables.reference_key_fn)(aggregate_name)];
    for key in candidates.into_iter().flatten() {
        if let Some((_, raw_id)) = pairs.iter().find(|(k, _)| k == key) {
            // A value-object identity arrives as `{"value": ...}`; `resolved_id_component`
            // unwraps it.
            let Some(id) = resolved_id_component(raw_id) else { continue };
            return Json::obj(vec![("to", Json::str(id)), ("with", Json::Object(facts))]);
        }
    }
    Json::Object(facts)
}

// Splits a one-level entity command ("Domain::Aggregate.Entity.Command") into aggregate and
// entity paths; `None` for any other depth. `split_once` because the domain boundary is `::`.
fn entity_command_paths(target_verb: &str) -> Option<(&str, String)> {
    let (aggregate_name, rest) = target_verb.split_once('.')?;
    let (entity_name, command_rest) = rest.split_once('.')?;
    if command_rest.contains('.') {
        return None;
    }
    Some((aggregate_name, format!("{aggregate_name}.{entity_name}")))
}

// A value-object field is stored as `{"value": ...}`: try the value as-is, then its `value` once.
fn resolved_id_component(v: &Json) -> Option<String> {
    v.to_id_component().ok().or_else(|| v.get("value").and_then(|inner| inner.to_id_component().ok())).filter(|id| !id.is_empty())
}

// Routes a one-level entity command that `split_routed_args` cannot: the parent aggregate's
// identity comes from the triggering event, not from the `with:` facts. Every other shape falls
// through to `split_routed_args`'s answer.
fn route_dispatch_args(projected: Json, target_verb: &str, tables: &Tables, event: &Event) -> Json {
    let routed = split_routed_args(projected.clone(), target_verb, tables);
    if matches!(&routed, Json::Object(fields) if fields.iter().any(|(k, _)| k == "to")) {
        return routed;
    }

    let Some((aggregate_name, entity_qualified)) = entity_command_paths(target_verb) else { return routed };
    let Json::Object(pairs) = &projected else { return routed };

    // Entity identity: its identity attribute, present in the `with:` facts by that name.
    let Some(entity_head) = (tables.entity_identity_head_fn)(&entity_qualified) else { return routed };
    let Some(entity_id) = pairs.iter().find(|(k, _)| k == entity_head).and_then(|(_, v)| resolved_id_component(v)) else {
        return routed;
    };

    // Aggregate identity: a projected identity/reference key, else the triggering event's own id
    // when it is the same aggregate.
    let candidates = [(tables.identity_head_fn)(aggregate_name), (tables.reference_key_fn)(aggregate_name)];
    let aggregate_id = candidates
        .into_iter()
        .flatten()
        .find_map(|key| pairs.iter().find(|(k, _)| k == key).and_then(|(_, v)| resolved_id_component(v)))
        .or_else(|| (event.aggregate == aggregate_name && !event.id.is_empty()).then(|| event.id.clone()));
    let Some(aggregate_id) = aggregate_id else { return routed };

    let declared = (tables.command_attributes_fn)(target_verb);
    let facts: Vec<(String, Json)> = pairs.iter().filter(|(k, _)| declared.contains(&k.as_str())).cloned().collect();
    Json::obj(vec![
        ("to", Json::obj(vec![("aggregate", Json::str(aggregate_id)), ("entities", Json::Array(vec![Json::str(entity_id)]))])),
        ("with", Json::Object(facts)),
    ])
}

#[allow(clippy::too_many_arguments)]
fn react_policies<S: AggregateScan>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>, Option<&str>, &mut Vec<MutationRecord>) -> Result<Vec<Event>, Refusal>,
    tables: Tables<'static>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    event: &Event,
    occurred_at: Option<&str>,
    depth: usize,
    all_events: &mut Vec<Event>,
    mutations: &mut Vec<MutationRecord>,
    cross_domain: &mut Vec<PendingCrossDomainReaction>,
    reaction_log: &mut Vec<Json>,
    saga_log: &mut Vec<Json>,
) {
    let emitting = event.aggregate.rsplit("::").next().unwrap_or(event.aggregate.as_str());

    for policy in tables.policies {
        if policy.event_name != event.name {
            continue;
        }
        if let Some(qualifier) = policy.event_qualifier {
            if qualifier != emitting {
                continue;
            }
        }
        if !where_holds(policy.where_expr, event) {
            continue;
        }

        let record = |extra: Vec<(&str, Json)>| -> Json {
            let mut fields = vec![
                ("policy", Json::str(policy.policy_name.to_string())),
                ("on", Json::str(event.name.clone())),
                ("trigger", Json::str(policy.target_verb.to_string())),
            ];
            fields.extend(extra.into_iter().map(|(k, v)| (k, v)));
            Json::obj(fields)
        };

        if depth + 1 >= MAX_REACTION_DEPTH {
            reaction_log.push(record(vec![
                ("delivered", Json::Bool(false)),
                ("reason", Json::str(format!("reaction depth {MAX_REACTION_DEPTH} reached"))),
            ]));
            continue;
        }

        // A fan-out dispatches once per row its query answers; the row id is merged into the
        // source a `with:` projection reads from.
        if let Some(for_each) = policy.for_each {
            let Some(def) = named_query::find(tables.queries, for_each) else {
                reaction_log.push(record(vec![
                    ("delivered", Json::Bool(false)),
                    ("reason", Json::str(format!("no query {for_each}"))),
                ]));
                continue;
            };
            // The query reads the event, not the projection. No caller role: the policy is
            // system-triggered.
            let rows = match named_query::run(store, def, &event.payload, None) {
                Ok(rows) => rows,
                Err(refusal) => {
                    reaction_log.push(record(vec![
                        ("delivered", Json::Bool(false)),
                        ("reason", Json::str(refusal.to_string())),
                    ]));
                    continue;
                }
            };
            for (row_id, row) in rows {
                let row_record = |extra: Vec<(&str, Json)>| -> Json {
                    let mut fields = vec![("for_row", Json::str(row_id.clone()))];
                    fields.extend(extra.into_iter());
                    let base = record(vec![]);
                    match base {
                        Json::Object(mut pairs) => {
                            pairs.extend(fields.into_iter().map(|(k, v)| (k.to_string(), v)));
                            Json::Object(pairs)
                        }
                        other => other,
                    }
                };
                let extra = policy.for_each_key.map(|key| (key, row_id.clone()));
                let args = trigger_args_with_row(policy, event, extra, Some((row_id.as_str(), &row)), policy.target_verb, &tables);
                let outcome = orchestrate(
                    store, dispatch_fn, tables, sagas, policy.target_verb, &args, None, None, None, occurred_at, depth + 1,
                    all_events, mutations, cross_domain, reaction_log, saga_log,
                );
                match outcome {
                    Ok(()) => reaction_log.push(row_record(vec![("delivered", Json::Bool(true))])),
                    Err(refusal) => reaction_log.push(row_record(vec![
                        ("delivered", Json::Bool(false)),
                        ("reason", Json::str(refusal.to_string())),
                    ])),
                }
            }
            continue;
        }

        // No `with:`: the whole payload forwards verbatim. Reactions are system-triggered, so no
        // caller role, and only saga legs stamp a correlation.
        let args = trigger_args(policy, event, None, policy.target_verb, &tables);
        let outcome = orchestrate(
            store, dispatch_fn, tables, sagas, policy.target_verb, &args, None, None, None, occurred_at, depth + 1,
            all_events, mutations, cross_domain, reaction_log, saga_log,
        );
        match outcome {
            Ok(()) => reaction_log.push(record(vec![("delivered", Json::Bool(true))])),
            // A refusal is recorded, not fatal to the emitting command. A panic is not caught, on
            // purpose.
            Err(refusal) => reaction_log.push(record(vec![
                ("delivered", Json::Bool(false)),
                ("reason", Json::str(refusal.to_string())),
            ])),
        }
    }

    // Cross-domain matches are recorded for the host to deliver, never dispatched or logged here:
    // the delivery outcome does not exist yet.
    for policy in tables.cross_domain_policies {
        if policy.event_name != event.name {
            continue;
        }
        if let Some(qualifier) = policy.event_qualifier {
            if qualifier != emitting {
                continue;
            }
        }
        if !where_holds(policy.where_expr, event) {
            continue;
        }
        cross_domain.push(PendingCrossDomainReaction {
            policy_name: policy.policy_name.to_string(),
            event_name: event.name.clone(),
            target_domain: policy.target_domain.to_string(),
            target_verb: policy.target_verb.to_string(),
            payload: event.payload.clone(),
        });
    }
}

// Silent when `event.name != pm.starts_on` or the instance already exists.
fn begin_saga(tables: Tables<'static>, sagas: &mut HashMap<(String, String), SagaInstance>, event: &Event, saga_log: &mut Vec<Json>) {
    for pm in tables.process_managers {
        if event.name != pm.starts_on {
            continue;
        }

        let Some(correlation) = correlation_of(pm, event, tables.reference_key_fn) else {
            saga_log.push(Json::obj(vec![
                ("process_manager", Json::str(pm.name.to_string())),
                ("on", Json::str(event.name.clone())),
                ("born", Json::Bool(false)),
                ("reason", Json::str(format!("no {} in the payload", pm.correlates_by))),
            ]));
            continue;
        };

        let key = (pm.name.to_string(), correlation.clone());
        if sagas.contains_key(&key) {
            continue;
        }

        sagas.insert(key, SagaInstance { state: pm.initial_state.to_string(), memory: event.payload.clone(), completed_compensations: Vec::new() });
        saga_log.push(Json::obj(vec![
            ("process_manager", Json::str(pm.name.to_string())),
            ("on", Json::str(event.name.clone())),
            ("instance", Json::str(correlation)),
            ("born", Json::Bool(true)),
            ("state", Json::str(pm.initial_state.to_string())),
        ]));
    }
}

// Silent when no handler answers the event or correlation resolves to nothing.
#[allow(clippy::too_many_arguments)]
fn advance_saga<S: AggregateScan>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>, Option<&str>, &mut Vec<MutationRecord>) -> Result<Vec<Event>, Refusal>,
    tables: Tables<'static>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    event: &Event,
    occurred_at: Option<&str>,
    depth: usize,
    all_events: &mut Vec<Event>,
    mutations: &mut Vec<MutationRecord>,
    cross_domain: &mut Vec<PendingCrossDomainReaction>,
    reaction_log: &mut Vec<Json>,
    saga_log: &mut Vec<Json>,
) {
    for pm in tables.process_managers {
        if !pm.handlers.iter().any(|h| h.event_type == event.name) {
            continue;
        }
        let Some(correlation) = correlation_of(pm, event, tables.reference_key_fn) else { continue };

        let key = (pm.name.to_string(), correlation.clone());
        let record = |extra: Vec<(&str, Json)>| -> Json {
            let mut fields = vec![
                ("process_manager", Json::str(pm.name.to_string())),
                ("on", Json::str(event.name.clone())),
                ("instance", Json::str(correlation.clone())),
            ];
            fields.extend(extra.into_iter().map(|(k, v)| (k, v)));
            Json::obj(fields)
        };

        let Some(state) = sagas.get(&key).map(|instance| instance.state.clone()) else {
            saga_log.push(record(vec![
                ("advanced", Json::Bool(false)),
                ("reason", Json::str(format!("no conversation remembers {correlation:?}"))),
            ]));
            continue;
        };
        // The leg is chosen by (event, current state); build refuses two on one pair.
        let Some(handler) = select_leg(pm, &event.name, &state) else {
            saga_log.push(record(vec![
                ("advanced", Json::Bool(false)),
                ("reason", Json::str(leg_mismatch(pm, &event.name, &state))),
            ]));
            continue;
        };

        if let Some(slot) = sagas.get_mut(&key) {
            slot.state = handler.to_state.to_string();
        }
        saga_log.push(record(vec![
            ("advanced", Json::Bool(true)),
            ("from", Json::str(handler.from_state.to_string())),
            ("to", Json::str(handler.to_state.to_string())),
        ]));

        let memory = sagas.get(&key).map(|instance| instance.memory.clone()).unwrap_or(Json::Null);
        // `event.aggregate` is `{domain}::{aggregate}`, so the domain is read from it.
        let domain_name = event.aggregate.split("::").next().unwrap_or(&event.aggregate);
        let mut refused = false;
        for spec in handler.dispatches {
            let args = build_dispatch_args(pm, spec, event, &correlation, &memory, domain_name, &tables);
            // Resolved before the forward dispatch: the ledger entry is pushed speculatively.
            let compensation_args = spec.compensates.map(|r| build_dispatch_args(pm, r, event, &correlation, &memory, domain_name, &tables));
            let stamp: HashMap<String, String> = [(correlation_head(pm.correlates_by).to_string(), correlation.clone())].into_iter().collect();
            let delivered = deliver_saga_dispatch(
                store, dispatch_fn, tables, sagas, pm, spec, domain_name, &args, &correlation, occurred_at, depth, all_events, mutations, cross_domain, reaction_log, saga_log, &stamp, compensation_args,
            );
            if delivered == Some(false) {
                refused = true;
            }
        }

        if refused {
            compensate(store, dispatch_fn, tables, sagas, pm, &key, event, &correlation, &memory, occurred_at, depth, all_events, mutations, cross_domain, reaction_log, saga_log);
        }
    }
}

// Returns `Some(delivered)`, or `None` when the depth ceiling stopped the leg before it tried.
// The compensation is pushed before the forward dispatch runs: a nested refusal re-entering this
// saga must already see it. It is popped again if this leg's own attempt refuses.
#[allow(clippy::too_many_arguments)]
fn deliver_saga_dispatch<S: AggregateScan>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>, Option<&str>, &mut Vec<MutationRecord>) -> Result<Vec<Event>, Refusal>,
    tables: Tables<'static>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    pm: &ProcessManagerDef,
    spec: &DispatchSpec,
    domain_name: &str,
    args: &Json,
    correlation: &str,
    occurred_at: Option<&str>,
    depth: usize,
    all_events: &mut Vec<Event>,
    mutations: &mut Vec<MutationRecord>,
    cross_domain: &mut Vec<PendingCrossDomainReaction>,
    reaction_log: &mut Vec<Json>,
    saga_log: &mut Vec<Json>,
    stamp: &HashMap<String, String>,
    compensation_args: Option<Json>,
) -> Option<bool> {
    // Ruby logs the unqualified name and qualifies only at dispatch; this mirrors that split.
    let record = |extra: Vec<(&str, Json)>| -> Json {
        let mut fields = vec![
            ("process_manager", Json::str(pm.name.to_string())),
            ("instance", Json::str(correlation.to_string())),
            ("dispatch", Json::str(spec.command_name.to_string())),
        ];
        fields.extend(extra.into_iter().map(|(k, v)| (k, v)));
        Json::obj(fields)
    };

    if depth + 1 >= MAX_REACTION_DEPTH {
        saga_log.push(record(vec![
            ("delivered", Json::Bool(false)),
            ("reason", Json::str(format!("reaction depth {MAX_REACTION_DEPTH} reached"))),
        ]));
        return None;
    }

    // `spec.command_name` is bare on the wire, so it is qualified before `dispatch_by_name`.
    let qualified = qualify_saga_command_name(domain_name, spec.command_name);

    let key = (pm.name.to_string(), correlation.to_string());
    let mut compensation_recorded = false;
    if let (Some(compensates_spec), Some(r_args)) = (spec.compensates, compensation_args) {
        if let Some(slot) = sagas.get_mut(&key) {
            slot.completed_compensations.push(CompletedCompensation { command_name: compensates_spec.command_name.to_string(), args: r_args });
            compensation_recorded = true;
        }
    }

    // System-triggered, so no caller role; `Some(stamp)` stamps every event this dispatch
    // produces.
    let outcome = orchestrate(
        store, dispatch_fn, tables, sagas, &qualified, args, None, None, Some(stamp), occurred_at, depth + 1,
        all_events, mutations, cross_domain, reaction_log, saga_log,
    );
    match outcome {
        Ok(()) => {
            saga_log.push(record(vec![("delivered", Json::Bool(true))]));
            Some(true)
        }
        Err(refusal) => {
            // This leg failed, so its speculative entry was never earned. `pop` is safe: any
            // entry pushed after it by a nested call was already drained by `compensate`.
            if compensation_recorded {
                if let Some(slot) = sagas.get_mut(&key) {
                    slot.completed_compensations.pop();
                }
            }
            saga_log.push(record(vec![
                ("delivered", Json::Bool(false)),
                ("reason", Json::str(refusal.to_string())),
            ]));
            Some(false)
        }
    }
}

// Fires one ledger entry, newest-first. Args are pre-resolved, so `build_dispatch_args` is
// skipped. A compensation that itself refuses is logged with `compensation_failed` and never
// re-triggers `compensate`.
#[allow(clippy::too_many_arguments)]
fn deliver_derived_compensation<S: AggregateScan>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>, Option<&str>, &mut Vec<MutationRecord>) -> Result<Vec<Event>, Refusal>,
    tables: Tables<'static>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    pm: &ProcessManagerDef,
    entry: &CompletedCompensation,
    domain_name: &str,
    correlation: &str,
    occurred_at: Option<&str>,
    depth: usize,
    all_events: &mut Vec<Event>,
    mutations: &mut Vec<MutationRecord>,
    cross_domain: &mut Vec<PendingCrossDomainReaction>,
    reaction_log: &mut Vec<Json>,
    saga_log: &mut Vec<Json>,
) {
    let record = |extra: Vec<(&str, Json)>| -> Json {
        let mut fields = vec![
            ("process_manager", Json::str(pm.name.to_string())),
            ("instance", Json::str(correlation.to_string())),
            ("dispatch", Json::str(entry.command_name.to_string())),
        ];
        fields.extend(extra.into_iter().map(|(k, v)| (k, v)));
        Json::obj(fields)
    };

    if depth + 1 >= MAX_REACTION_DEPTH {
        saga_log.push(record(vec![
            ("delivered", Json::Bool(false)),
            ("reason", Json::str(format!("reaction depth {MAX_REACTION_DEPTH} reached"))),
            ("compensation", Json::Bool(true)),
            ("compensation_failed", Json::Bool(true)),
        ]));
        return;
    }

    // A compensation's `command_name` is bare on the wire, like a forward dispatch's.
    let qualified = qualify_saga_command_name(domain_name, &entry.command_name);

    let stamp: HashMap<String, String> = [(correlation_head(pm.correlates_by).to_string(), correlation.to_string())].into_iter().collect();

    let outcome = orchestrate(
        store, dispatch_fn, tables, sagas, &qualified, &entry.args, None, None, Some(&stamp), occurred_at, depth + 1,
        all_events, mutations, cross_domain, reaction_log, saga_log,
    );
    match outcome {
        Ok(()) => saga_log.push(record(vec![("delivered", Json::Bool(true)), ("compensation", Json::Bool(true))])),
        Err(refusal) => saga_log.push(record(vec![
            ("delivered", Json::Bool(false)),
            ("reason", Json::str(refusal.to_string())),
            ("compensation", Json::Bool(true)),
            ("compensation_failed", Json::Bool(true)),
        ])),
    }
}

// Silent when `event.name != pm.ends_on`, correlation is absent, or no instance existed.
fn end_saga(tables: Tables<'static>, sagas: &mut HashMap<(String, String), SagaInstance>, event: &Event, saga_log: &mut Vec<Json>) {
    for pm in tables.process_managers {
        if event.name != pm.ends_on {
            continue;
        }
        let Some(correlation) = correlation_of(pm, event, tables.reference_key_fn) else { continue };
        let key = (pm.name.to_string(), correlation.clone());
        if sagas.remove(&key).is_none() {
            continue;
        }

        saga_log.push(Json::obj(vec![
            ("process_manager", Json::str(pm.name.to_string())),
            ("on", Json::str(event.name.clone())),
            ("instance", Json::str(correlation)),
            ("ended", Json::Bool(true)),
        ]));
    }
}

// The `on :refused` leg, run once against the post-transition state. Its own dispatches never
// compensate on failure.
#[allow(clippy::too_many_arguments)]
fn compensate<S: AggregateScan>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>, Option<&str>, &mut Vec<MutationRecord>) -> Result<Vec<Event>, Refusal>,
    tables: Tables<'static>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    pm: &ProcessManagerDef,
    key: &(String, String),
    event: &Event,
    correlation: &str,
    memory: &Json,
    occurred_at: Option<&str>,
    depth: usize,
    all_events: &mut Vec<Event>,
    mutations: &mut Vec<MutationRecord>,
    cross_domain: &mut Vec<PendingCrossDomainReaction>,
    reaction_log: &mut Vec<Json>,
    saga_log: &mut Vec<Json>,
) {
    let Some(current_state) = sagas.get(key).map(|instance| instance.state.clone()) else { return };
    // A process manager with no compensating leg is silent; a state no leg answers from is logged
    // as `advanced: false`.
    if !pm.handlers.iter().any(|h| h.event_type == REFUSED) {
        return;
    }

    let record = |extra: Vec<(&str, Json)>| -> Json {
        let mut fields = vec![
            ("process_manager", Json::str(pm.name.to_string())),
            ("on", Json::str(REFUSED.to_string())),
            ("instance", Json::str(correlation.to_string())),
        ];
        fields.extend(extra.into_iter().map(|(k, v)| (k, v)));
        Json::obj(fields)
    };

    let Some(compensation) = select_leg(pm, REFUSED, &current_state) else {
        saga_log.push(record(vec![
            ("advanced", Json::Bool(false)),
            ("reason", Json::str(leg_mismatch(pm, REFUSED, &current_state))),
        ]));
        return;
    };

    if let Some(slot) = sagas.get_mut(key) {
        slot.state = compensation.to_state.to_string();
    }
    saga_log.push(record(vec![
        ("advanced", Json::Bool(true)),
        ("from", Json::str(compensation.from_state.to_string())),
        ("to", Json::str(compensation.to_state.to_string())),
    ]));

    let domain_name = event.aggregate.split("::").next().unwrap_or(&event.aggregate);

    // Derived compensations first, newest-first. The ledger is re-fetched each iteration, not
    // snapshotted: a nested reaction may push onto it mid-drain. If one removes the instance
    // mid-drain, the loop stops early.
    loop {
        let entry = match sagas.get_mut(key) {
            Some(instance) => instance.completed_compensations.pop(),
            None => None,
        };
        let Some(entry) = entry else { break };
        deliver_derived_compensation(store, dispatch_fn, tables, sagas, pm, &entry, domain_name, correlation, occurred_at, depth, all_events, mutations, cross_domain, reaction_log, saga_log);
    }

    for spec in compensation.dispatches {
        let args = build_dispatch_args(pm, spec, event, correlation, memory, domain_name, &tables);
        let compensation_args = spec.compensates.map(|r| build_dispatch_args(pm, r, event, correlation, memory, domain_name, &tables));
        let stamp: HashMap<String, String> = [(correlation_head(pm.correlates_by).to_string(), correlation.to_string())].into_iter().collect();
        deliver_saga_dispatch(
            store, dispatch_fn, tables, sagas, pm, spec, domain_name, &args, correlation, occurred_at, depth, all_events, mutations, cross_domain, reaction_log, saga_log, &stamp, compensation_args,
        );
    }
}

#[cfg(test)]
#[path = "orchestrate_guard_tests.rs"]
mod guard_tests;

#[cfg(test)]
mod tests {
    use super::*;

    // Pins the decode of a rendered `with:` literal: raw wire text reaching `from_json` left the
    // trigger silently unfired.
    #[test]
    fn decodes_a_quoted_string_literal_back_to_its_bare_value() {
        assert_eq!(read_literal_wire("\"officer\""), Json::str("officer"));
    }

    #[test]
    fn unescapes_an_embedded_quote_or_backslash_the_same_way_literal_quote_escaped_it() {
        assert_eq!(read_literal_wire("\"a\\\"b\\\\c\""), Json::str("a\"b\\c"));
    }

    #[test]
    fn decodes_the_bare_scalar_forms_literal_render_never_quotes() {
        assert_eq!(read_literal_wire("nil"), Json::Null);
        assert_eq!(read_literal_wire("true"), Json::Bool(true));
        assert_eq!(read_literal_wire("false"), Json::Bool(false));
        assert_eq!(read_literal_wire("42"), Json::int(42));
        assert_eq!(read_literal_wire("3.5"), Json::Float(3.5));
    }

    #[test]
    fn passes_a_bare_unrendered_word_through_unchanged() {
        assert_eq!(read_literal_wire("officer"), Json::str("officer"));
    }

    fn pm(correlates_by: &'static str) -> ProcessManagerDef {
        ProcessManagerDef {
            name: "TestSaga",
            correlates_by,
            starts_on: "Started",
            ends_on: "Ended",
            initial_state: "start",
            handlers: &[],
        }
    }

    fn no_reference_key(_aggregate: &str) -> Option<&'static str> {
        None
    }

    // Tier 2 alone: tier 1 finds nothing and tier 3 is unconfigured, so only the stamp can
    // resolve it.
    #[test]
    fn correlation_of_reads_the_stamp_when_the_payload_has_nothing_and_no_reference_key_applies() {
        let pm = pm("reference.value");
        let event = Event {
            name: "SomeEvent".to_string(),
            aggregate: "Domain::Thing".to_string(),
            id: "thing-1".to_string(),
            payload: Json::Object(vec![]),
            occurred_at: None,
            correlation: Some([("reference".to_string(), "xfer-1".to_string())].into_iter().collect()),
        };

        assert_eq!(correlation_of(&pm, &event, no_reference_key), Some("xfer-1".to_string()));
    }

    #[test]
    fn correlation_of_prefers_tier_1_over_the_stamp_when_both_are_present() {
        let pm = pm("reference.value");
        let event = Event {
            name: "SomeEvent".to_string(),
            aggregate: "Domain::Thing".to_string(),
            id: "thing-1".to_string(),
            payload: Json::Object(vec![("reference".to_string(), Json::Object(vec![("value".to_string(), Json::Str("from-payload".to_string()))]))]),
            occurred_at: None,
            correlation: Some([("reference".to_string(), "from-stamp".to_string())].into_iter().collect()),
        };

        assert_eq!(correlation_of(&pm, &event, no_reference_key), Some("from-payload".to_string()));
    }

    #[test]
    fn correlation_of_ignores_an_empty_stamped_value_and_falls_through() {
        let pm = pm("reference.value");
        let event = Event {
            name: "SomeEvent".to_string(),
            aggregate: "Domain::Thing".to_string(),
            id: "thing-1".to_string(),
            payload: Json::Object(vec![]),
            occurred_at: None,
            correlation: Some([("reference".to_string(), String::new())].into_iter().collect()),
        };

        assert_eq!(correlation_of(&pm, &event, no_reference_key), None);
    }

    // The stamping step of `orchestrate`, exercised without a real `dispatch_fn`.
    #[test]
    fn stamping_merges_into_an_existing_correlation_map_rather_than_replacing_it() {
        let mut events = vec![
            Event {
                name: "E".to_string(),
                aggregate: "Domain::Thing".to_string(),
                id: "thing-1".to_string(),
                payload: Json::Null,
                occurred_at: None,
                correlation: Some([("already".to_string(), "here".to_string())].into_iter().collect()),
            },
        ];
        let stamp: HashMap<String, String> = [("reference".to_string(), "xfer-1".to_string())].into_iter().collect();
        for event in &mut events {
            event.correlation.get_or_insert_with(HashMap::new).extend(stamp.iter().map(|(k, v)| (k.clone(), v.clone())));
        }

        let correlation = events[0].correlation.as_ref().unwrap();
        assert_eq!(correlation.get("already"), Some(&"here".to_string()));
        assert_eq!(correlation.get("reference"), Some(&"xfer-1".to_string()));
    }

    // The `occurred_at` stamping step of `orchestrate`, exercised the same way.
    #[test]
    fn occurred_at_stamps_every_event_the_same_host_supplied_moment() {
        let mut events = vec![
            Event { name: "A".to_string(), aggregate: "Domain::Thing".to_string(), id: "t1".to_string(), payload: Json::Null, occurred_at: None, correlation: None },
            Event { name: "B".to_string(), aggregate: "Domain::Thing".to_string(), id: "t2".to_string(), payload: Json::Null, occurred_at: None, correlation: None },
        ];
        let occurred_at = Some("2026-08-28T00:00:00Z");

        if let Some(ts) = occurred_at {
            for event in &mut events {
                event.occurred_at = Some(ts.to_string());
            }
        }

        assert_eq!(events[0].occurred_at, Some("2026-08-28T00:00:00Z".to_string()));
        assert_eq!(events[1].occurred_at, Some("2026-08-28T00:00:00Z".to_string()));
    }

    #[test]
    fn occurred_at_leaves_events_unstamped_when_no_caller_supplied_one() {
        let mut events = vec![Event { name: "A".to_string(), aggregate: "Domain::Thing".to_string(), id: "t1".to_string(), payload: Json::Null, occurred_at: None, correlation: None }];
        let occurred_at: Option<&str> = None;

        if let Some(ts) = occurred_at {
            for event in &mut events {
                event.occurred_at = Some(ts.to_string());
            }
        }

        assert_eq!(events[0].occurred_at, None);
    }

    // Pins the speculative ledger record: legs A, B, C where C refuses two calls deep, before A's
    // and B's `deliver_saga_dispatch` return. Recording after success would leave the ledger empty
    // when `compensate` drains it, so neither `RA` nor `RB` would fire.
    struct MultiLegTestStore;
    impl AggregateScan for MultiLegTestStore {}

    fn multi_leg_test_dispatch(
        _store: &mut MultiLegTestStore,
        verb: &str,
        _args: &Json,
        _caller_role: Option<&str>,
        _caller_actor_id: Option<&str>,
        _mutations: &mut Vec<MutationRecord>,
    ) -> Result<Vec<Event>, Refusal> {
        let plain_event = |name: &str| Event {
            name: name.to_string(),
            aggregate: "Test::Widget".to_string(),
            id: "w1".to_string(),
            payload: Json::Object(vec![]),
            occurred_at: None,
            correlation: None,
        };
        match verb {
            "Test::Kickoff" => Ok(vec![Event {
                name: "Started".to_string(),
                aggregate: "Test::Widget".to_string(),
                id: "w1".to_string(),
                payload: Json::obj(vec![("id", Json::str("corr-1"))]),
                occurred_at: None,
                correlation: None,
            }]),
            "Test::A" => Ok(vec![plain_event("AEvent")]),
            "Test::B" => Ok(vec![plain_event("BEvent")]),
            "Test::C" => Err(Refusal::GivenNotMet("C always refuses".to_string())),
            "Test::RA" | "Test::RB" => Ok(vec![]),
            other => panic!("unexpected verb in multi-leg reentrancy test: {other}"),
        }
    }

    fn multi_leg_no_reference_key(_aggregate: &str) -> Option<&'static str> {
        None
    }
    fn multi_leg_always_creates(_verb: &str) -> bool {
        true
    }
    fn multi_leg_no_identity_head(_aggregate: &str) -> Option<&'static str> {
        None
    }
    fn multi_leg_no_declared_attributes(_verb: &str) -> &'static [&'static str] {
        &[]
    }
    fn multi_leg_no_entity_identity_head(_qualified_path: &str) -> Option<&'static str> {
        None
    }

    #[test]
    fn multi_leg_reentrant_saga_fires_completed_compensations_newest_first_on_a_later_legs_refusal() {
        // `DISPATCH_RA`/`RB` are named statics; the forward legs are inline literals because a
        // static's value cannot be moved into an array (`DispatchSpec` is not `Copy`).
        static DISPATCH_RA: DispatchSpec = DispatchSpec { command_name: "RA", with: &[], compensates: None };
        static DISPATCH_RB: DispatchSpec = DispatchSpec { command_name: "RB", with: &[], compensates: None };

        static HANDLERS: &[Handler] = &[
            Handler {
                event_type: "Started",
                from_state: "start",
                to_state: "state1",
                dispatches: &[DispatchSpec { command_name: "A", with: &[], compensates: Some(&DISPATCH_RA) }],
            },
            Handler {
                event_type: "AEvent",
                from_state: "state1",
                to_state: "state2",
                dispatches: &[DispatchSpec { command_name: "B", with: &[], compensates: Some(&DISPATCH_RB) }],
            },
            Handler {
                event_type: "BEvent",
                from_state: "state2",
                to_state: "state3",
                dispatches: &[DispatchSpec { command_name: "C", with: &[], compensates: None }],
            },
            Handler { event_type: REFUSED, from_state: "state3", to_state: "compensated", dispatches: &[] },
        ];

        static PROCESS_MANAGERS: &[ProcessManagerDef] = &[ProcessManagerDef {
            name: "TestMultiLeg",
            correlates_by: "id",
            starts_on: "Started",
            ends_on: "NeverHappens",
            initial_state: "start",
            handlers: HANDLERS,
        }];
        static POLICIES: &[PolicyRule] = &[];
        static CROSS_DOMAIN_POLICIES: &[CrossDomainPolicyRule] = &[];
        static QUERIES: &[crate::kernel::QueryDef] = &[];

        let tables = Tables {
            policies: POLICIES,
            cross_domain_policies: CROSS_DOMAIN_POLICIES,
            process_managers: PROCESS_MANAGERS,
            reference_key_fn: multi_leg_no_reference_key,
            queries: QUERIES,
            command_creates_fn: multi_leg_always_creates,
            identity_head_fn: multi_leg_no_identity_head,
            command_attributes_fn: multi_leg_no_declared_attributes,
            entity_identity_head_fn: multi_leg_no_entity_identity_head,
        };

        let mut store = MultiLegTestStore;
        let mut sagas: HashMap<(String, String), SagaInstance> = HashMap::new();
        let mut all_events = Vec::new();
        let mut mutations = Vec::new();
        let mut cross_domain = Vec::new();
        let mut reaction_log = Vec::new();
        let mut saga_log: Vec<Json> = Vec::new();

        let outcome = orchestrate(
            &mut store,
            multi_leg_test_dispatch,
            tables,
            &mut sagas,
            "Test::Kickoff",
            &Json::Object(vec![]),
            None,
            None,
            None,
            None,
            0,
            &mut all_events,
            &mut mutations,
            &mut cross_domain,
            &mut reaction_log,
            &mut saga_log,
        );
        assert!(outcome.is_ok(), "top-level Kickoff should not itself refuse: {outcome:?}");

        let key = ("TestMultiLeg".to_string(), "corr-1".to_string());
        let instance = sagas.get(&key).expect("the saga instance should still exist (it never reaches ends_on)");
        assert_eq!(instance.state, "compensated", "the saga should have unwound to the on-:refused leg's own to_state");
        assert!(instance.completed_compensations.is_empty(), "the ledger should be fully drained after compensate runs");

        let dispatch_entries: Vec<(String, bool, bool)> = saga_log
            .iter()
            .filter_map(|entry| {
                let dispatch = entry.get("dispatch")?.as_str()?.to_string();
                let delivered = matches!(entry.get("delivered"), Some(Json::Bool(true)));
                let compensation = matches!(entry.get("compensation"), Some(Json::Bool(true)));
                Some((dispatch, delivered, compensation))
            })
            .collect();

        // The order is the assertion: C refuses, RB then RA fire newest-first, then B and A log
        // delivered once their cascades return. It holds only if the ledger was filled before
        // `compensate` drained it.
        assert_eq!(
            dispatch_entries,
            vec![
                ("C".to_string(), false, false),
                ("RB".to_string(), true, true),
                ("RA".to_string(), true, true),
                ("B".to_string(), true, false),
                ("A".to_string(), true, false),
            ],
            "expected C to refuse, then RB and RA to fire as derived compensations newest-first, \
             then B's and A's own forward dispatches to be logged delivered once their \
             downstream cascade returns — saga_log was: {saga_log:?}"
        );
    }

    // Stands in for a command whose generated `refuse_absent_arguments` lists `now` as declared
    // and non-optional: it refuses when `now` is missing and records what the gates saw.
    thread_local! { static SEEN: std::cell::RefCell<Option<Json>> = const { std::cell::RefCell::new(None) }; }
    fn strict_now_dispatch(
        _store: &mut MultiLegTestStore,
        _verb: &str,
        args: &Json,
        _caller_role: Option<&str>,
        _caller_actor_id: Option<&str>,
        _mutations: &mut Vec<MutationRecord>,
    ) -> Result<Vec<Event>, Refusal> {
        let facts = args.get("with").unwrap_or(args);
        if facts.get("now").is_none() {
            return Err(Refusal::GivenNotMet("absent argument: now".to_string()));
        }
        SEEN.with(|s| *s.borrow_mut() = Some(facts.clone()));
        Ok(vec![])
    }

    fn run_strict_now(verb: &str, args: &Json, occurred_at: Option<&str>) -> Result<(), Refusal> {
        static NONE_P: &[PolicyRule] = &[];
        static NONE_X: &[CrossDomainPolicyRule] = &[];
        static NONE_M: &[ProcessManagerDef] = &[];
        static NONE_Q: &[crate::kernel::QueryDef] = &[];
        let tables = Tables {
            policies: NONE_P,
            cross_domain_policies: NONE_X,
            process_managers: NONE_M,
            reference_key_fn: multi_leg_no_reference_key,
            queries: NONE_Q,
            command_creates_fn: multi_leg_always_creates,
            identity_head_fn: multi_leg_no_identity_head,
            command_attributes_fn: multi_leg_no_declared_attributes,
            entity_identity_head_fn: multi_leg_no_entity_identity_head,
        };
        SEEN.with(|s| *s.borrow_mut() = None);
        orchestrate(
            &mut MultiLegTestStore,
            strict_now_dispatch,
            tables,
            &mut HashMap::new(),
            verb,
            args,
            None,
            None,
            None,
            occurred_at,
            0,
            &mut Vec::new(),
            &mut Vec::new(),
            &mut Vec::new(),
            &mut Vec::new(),
            &mut Vec::new(),
        )
    }

    // Both kernel-path guarantees at once: the fill lands before the absent-argument gate runs, so
    // the strict refusal does not fire for a needed fact, and a supplied value is the one the
    // gates see.
    #[test]
    fn a_needed_fact_is_answered_before_the_absent_argument_gate_and_a_supplied_one_is_kept() {
        let table = Json::parse(r#"{"T::Slot.Lease": [{"fact": "now", "type": "Integer"}]}"#).unwrap();
        crate::kernel::needs::install(Some(&table));
        crate::kernel::needs::fix_clock(Some(77));

        let args = Json::obj(vec![("with", Json::obj(vec![("holder", Json::str("a"))]))]);
        assert!(run_strict_now("T::Slot.Lease", &args, None).is_ok());
        SEEN.with(|s| assert_eq!(s.borrow().as_ref().unwrap().get("now"), Some(&Json::int(77))));

        let supplied = Json::obj(vec![("with", Json::obj(vec![("now", Json::int(5))]))]);
        assert!(run_strict_now("T::Slot.Lease", &supplied, None).is_ok());
        SEEN.with(|s| assert_eq!(s.borrow().as_ref().unwrap().get("now"), Some(&Json::int(5))));

        // A command that declares no need keeps the strict refusal.
        assert!(run_strict_now("T::Slot.Other", &args, None).is_err());

        crate::kernel::needs::fix_clock(None);
        crate::kernel::needs::install(None);
    }

    // Pins domain-qualifying a same-domain entity command (`Manifest::Slot.Fill`): its leftover
    // `::` looks cross-domain, and an unqualified name would fail as an unknown command. The fake
    // dispatch panics on any verb but the qualified, dot-joined form.
    fn entity_command_test_dispatch(
        _store: &mut MultiLegTestStore,
        verb: &str,
        _args: &Json,
        _caller_role: Option<&str>,
        _caller_actor_id: Option<&str>,
        _mutations: &mut Vec<MutationRecord>,
    ) -> Result<Vec<Event>, Refusal> {
        let plain_event = |name: &str| Event {
            name: name.to_string(),
            aggregate: "Test::Manifest".to_string(),
            id: "m1".to_string(),
            payload: Json::Object(vec![]),
            occurred_at: None,
            correlation: None,
        };
        match verb {
            "Test::Kickoff" => Ok(vec![Event {
                name: "Started".to_string(),
                aggregate: "Test::Manifest".to_string(),
                id: "m1".to_string(),
                payload: Json::obj(vec![("id", Json::str("corr-1"))]),
                occurred_at: None,
                correlation: None,
            }]),
            // The qualified, dot-joined shape a generated `registry.rs` arm uses.
            "Test::Manifest.Slot.Fill" => Ok(vec![plain_event("SlotFilled")]),
            other => panic!("unexpected verb in entity-command qualification test (BUG#9): {other}"),
        }
    }

    #[test]
    fn a_saga_leg_dispatching_a_same_domain_entity_command_is_domain_qualified_and_dot_folded() {
        static HANDLERS: &[Handler] = &[
            Handler {
                event_type: "Started",
                from_state: "start",
                to_state: "filling",
                // Bare on the wire, entity-nested.
                dispatches: &[DispatchSpec { command_name: "Manifest::Slot.Fill", with: &[], compensates: None }],
            },
        ];

        static PROCESS_MANAGERS: &[ProcessManagerDef] = &[ProcessManagerDef {
            name: "TestPacking",
            correlates_by: "id",
            starts_on: "Started",
            ends_on: "NeverHappens",
            initial_state: "start",
            handlers: HANDLERS,
        }];
        static POLICIES: &[PolicyRule] = &[];
        static CROSS_DOMAIN_POLICIES: &[CrossDomainPolicyRule] = &[];
        static QUERIES: &[crate::kernel::QueryDef] = &[];

        let tables = Tables {
            policies: POLICIES,
            cross_domain_policies: CROSS_DOMAIN_POLICIES,
            process_managers: PROCESS_MANAGERS,
            reference_key_fn: multi_leg_no_reference_key,
            queries: QUERIES,
            command_creates_fn: multi_leg_always_creates,
            identity_head_fn: multi_leg_no_identity_head,
            command_attributes_fn: multi_leg_no_declared_attributes,
            entity_identity_head_fn: multi_leg_no_entity_identity_head,
        };

        let mut store = MultiLegTestStore;
        let mut sagas: HashMap<(String, String), SagaInstance> = HashMap::new();
        let mut all_events = Vec::new();
        let mut mutations = Vec::new();
        let mut cross_domain = Vec::new();
        let mut reaction_log = Vec::new();
        let mut saga_log: Vec<Json> = Vec::new();

        let outcome = orchestrate(
            &mut store,
            entity_command_test_dispatch,
            tables,
            &mut sagas,
            "Test::Kickoff",
            &Json::Object(vec![]),
            None,
            None,
            None,
            None,
            0,
            &mut all_events,
            &mut mutations,
            &mut cross_domain,
            &mut reaction_log,
            &mut saga_log,
        );
        assert!(outcome.is_ok(), "top-level Kickoff should not itself refuse: {outcome:?}");

        let dispatch_entries: Vec<(String, bool)> = saga_log
            .iter()
            .filter_map(|entry| {
                let dispatch = entry.get("dispatch")?.as_str()?.to_string();
                let delivered = matches!(entry.get("delivered"), Some(Json::Bool(true)));
                Some((dispatch, delivered))
            })
            .collect();

        assert_eq!(
            dispatch_entries,
            vec![("Manifest::Slot.Fill".to_string(), true)],
            "the entity-owned command's own saga leg should have been correctly domain-qualified \
             and delivered — not refused \"unknown command\" the way the pre-BUG#9 heuristic left \
             it — saga_log was: {saga_log:?}"
        );
    }

    #[test]
    fn qualify_saga_command_name_folds_a_same_domain_entity_command_reference() {
        assert_eq!(qualify_saga_command_name("Waybill", "Manifest::Slot.Fill"), "Waybill::Manifest.Slot.Fill");
        assert_eq!(qualify_saga_command_name("Waybill", "Manifest::Slot.Clear"), "Waybill::Manifest.Slot.Clear");
        // A plain aggregate command is only domain-prefixed.
        assert_eq!(qualify_saga_command_name("Waybill", "Manifest.Open"), "Waybill::Manifest.Open");
        assert_eq!(qualify_saga_command_name("Waybill", "Manifest.AddSlot"), "Waybill::Manifest.AddSlot");
    }

    // Fixture: non-creating `Widgets::Ledger.Grant`, identity head `email`, declared attribute
    // `role`.
    fn routed_identity_head(aggregate: &str) -> Option<&'static str> {
        (aggregate == "Widgets::Ledger").then_some("email")
    }
    fn routed_declared_attributes(verb: &str) -> &'static [&'static str] {
        if verb == "Widgets::Ledger.Grant" {
            &["role"]
        } else {
            &[]
        }
    }
    fn routed_reference_key_never_found(_aggregate: &str) -> Option<&'static str> {
        None
    }
    fn routed_entity_identity_head_never_found(_qualified_path: &str) -> Option<&'static str> {
        None
    }
    fn routed_never_creates(_verb: &str) -> bool {
        false
    }
    fn routed_fixture_tables() -> Tables<'static> {
        Tables {
            policies: &[],
            cross_domain_policies: &[],
            process_managers: &[],
            reference_key_fn: routed_reference_key_never_found,
            queries: &[],
            command_creates_fn: routed_never_creates,
            identity_head_fn: routed_identity_head,
            command_attributes_fn: routed_declared_attributes,
            entity_identity_head_fn: routed_entity_identity_head_never_found,
        }
    }

    fn routed_to_a_receiver(id: &str) -> Json {
        Json::obj(vec![("to", Json::str(id)), ("with", Json::obj(vec![("role", Json::str("Admin"))]))])
    }

    #[test]
    fn split_routed_args_routes_a_value_object_identity_as_the_receiver() {
        // A value-object identity is `{"value": ...}` in an event payload and forwards as that
        // object.
        let projected = Json::obj(vec![("email", Json::obj(vec![("value", Json::str("a@b.co"))])), ("role", Json::str("Admin"))]);

        let routed = split_routed_args(projected, "Widgets::Ledger.Grant", &routed_fixture_tables());

        assert_eq!(routed, routed_to_a_receiver("a@b.co"), "a VO identity should route as `to` — got {routed:?}");
    }

    #[test]
    fn split_routed_args_still_routes_a_bare_scalar_identity() {
        let projected = Json::obj(vec![("email", Json::str("a@b.co")), ("role", Json::str("Admin"))]);

        let routed = split_routed_args(projected, "Widgets::Ledger.Grant", &routed_fixture_tables());

        assert_eq!(routed, routed_to_a_receiver("a@b.co"), "a scalar identity should route as `to` — got {routed:?}");
    }

    #[test]
    fn split_routed_args_leaves_the_args_flat_when_the_identity_is_empty_or_not_a_value() {
        let flat = Json::obj(vec![("role", Json::str("Admin"))]);
        let empty = Json::obj(vec![("email", Json::obj(vec![("value", Json::str(""))])), ("role", Json::str("Admin"))]);
        let unrelated = Json::obj(vec![("email", Json::obj(vec![("other", Json::str("a@b.co"))])), ("role", Json::str("Admin"))]);

        for projected in [empty, unrelated] {
            let routed = split_routed_args(projected, "Widgets::Ledger.Grant", &routed_fixture_tables());
            assert_eq!(routed, flat, "an unusable identity should leave only the declared facts — got {routed:?}");
        }
    }

    #[test]
    fn entity_command_paths_only_matches_a_one_level_deep_entity_command() {
        assert_eq!(
            entity_command_paths("Waybill::Manifest.Slot.Fill"),
            Some(("Waybill::Manifest", "Waybill::Manifest.Slot".to_string()))
        );
        assert_eq!(entity_command_paths("Waybill::Manifest.AddSlot"), None);
        // A two-level entity command is deliberately not routed.
        assert_eq!(entity_command_paths("Domain::Workspace.Board.Card.Annotate"), None);
    }

    // Fixture: one-level entity command `Widgets::Crate.Slot.Fill` whose `with:` carries the
    // entity's identity (`number`) but not the parent aggregate's.
    fn bug10_entity_identity_head(qualified_path: &str) -> Option<&'static str> {
        (qualified_path == "Widgets::Crate.Slot").then_some("number")
    }
    fn bug10_declared_attributes(verb: &str) -> &'static [&'static str] {
        if verb == "Widgets::Crate.Slot.Fill" {
            &["item"]
        } else {
            &[]
        }
    }
    fn bug10_identity_head_never_found(_aggregate: &str) -> Option<&'static str> {
        None
    }
    fn bug10_reference_key_never_found(_aggregate: &str) -> Option<&'static str> {
        None
    }
    fn bug10_never_creates(_verb: &str) -> bool {
        false
    }
    fn bug10_fixture_tables() -> Tables<'static> {
        Tables {
            policies: &[],
            cross_domain_policies: &[],
            process_managers: &[],
            reference_key_fn: bug10_reference_key_never_found,
            queries: &[],
            command_creates_fn: bug10_never_creates,
            identity_head_fn: bug10_identity_head_never_found,
            command_attributes_fn: bug10_declared_attributes,
            entity_identity_head_fn: bug10_entity_identity_head,
        }
    }

    #[test]
    fn route_dispatch_args_threads_the_triggering_events_aggregate_identity_into_a_one_level_entity_commands_route() {
        // `number` is VO-nested; the parent aggregate's identity comes only from the triggering
        // event.
        let tables = bug10_fixture_tables();
        let projected = Json::obj(vec![("number", Json::obj(vec![("value", Json::int(7))])), ("item", Json::str("hello"))]);
        let event = Event {
            name: "SlotAdded".to_string(),
            aggregate: "Widgets::Crate".to_string(),
            id: "crate-1".to_string(),
            payload: Json::Object(vec![]),
            occurred_at: None,
            correlation: None,
        };

        let routed = route_dispatch_args(projected, "Widgets::Crate.Slot.Fill", &tables, &event);
        assert_eq!(
            routed,
            Json::obj(vec![
                ("to", Json::obj(vec![("aggregate", Json::str("crate-1")), ("entities", Json::Array(vec![Json::str("7")]))])),
                ("with", Json::obj(vec![("item", Json::str("hello"))])),
            ]),
            "should route to {{aggregate: crate-1, entities: [7]}} with facts sliced to Fill's own \
             declared attributes, mirroring Ruby's ReactionInvocation.build/source_receiver_for — \
             got {routed:?}"
        );
    }

    #[test]
    fn route_dispatch_args_falls_through_unchanged_when_the_triggering_event_is_a_different_aggregate() {
        // The triggering event is a different aggregate, so no receiver may be invented: falls
        // through unrouted.
        let tables = bug10_fixture_tables();
        let projected = Json::obj(vec![("number", Json::obj(vec![("value", Json::int(7))])), ("item", Json::str("hello"))]);
        let event = Event {
            name: "SomethingElseHappened".to_string(),
            aggregate: "Widgets::OtherThing".to_string(),
            id: "other-1".to_string(),
            payload: Json::Object(vec![]),
            occurred_at: None,
            correlation: None,
        };

        let routed = route_dispatch_args(projected, "Widgets::Crate.Slot.Fill", &tables, &event);
        assert_eq!(
            routed,
            Json::obj(vec![("item", Json::str("hello"))]),
            "with no aggregate identity anywhere (not in the projected facts, and the triggering \
             event names a different aggregate entirely), this must fall through to split_routed_\
             args's own unrouted, declared-attributes-only answer, never invent a receiver — \
             got {routed:?}"
        );
    }

    // Two legs on one event from different states, each reached exactly when its `from:` is
    // current.
    fn two_leg_test_dispatch(
        _store: &mut MultiLegTestStore,
        verb: &str,
        _args: &Json,
        _caller_role: Option<&str>,
        _caller_actor_id: Option<&str>,
        _mutations: &mut Vec<MutationRecord>,
    ) -> Result<Vec<Event>, Refusal> {
        let event = |name: &str| Event {
            name: name.to_string(),
            aggregate: "Test::Parcel".to_string(),
            id: "p1".to_string(),
            payload: Json::obj(vec![("id", Json::str("p1"))]),
            occurred_at: None,
            correlation: None,
        };
        match verb {
            "Test::Post" => Ok(vec![event("Posted"), event("Scanned"), event("Scanned")]),
            "Test::Deliver" => Ok(vec![event("Delivered")]),
            other => panic!("unexpected verb in two-leg selection test: {other}"),
        }
    }

    #[test]
    fn a_saga_leg_is_selected_by_event_and_current_state_so_two_legs_on_one_event_are_both_reachable() {
        static HANDLERS: &[Handler] = &[
            Handler { event_type: "Scanned", from_state: "posted", to_state: "picked_up", dispatches: &[] },
            Handler {
                event_type: "Scanned",
                from_state: "picked_up",
                to_state: "handed_over",
                dispatches: &[DispatchSpec { command_name: "Deliver", with: &[], compensates: None }],
            },
        ];
        static PROCESS_MANAGERS: &[ProcessManagerDef] = &[ProcessManagerDef {
            name: "Delivery",
            correlates_by: "id",
            starts_on: "Posted",
            ends_on: "Delivered",
            initial_state: "posted",
            handlers: HANDLERS,
        }];
        static POLICIES: &[PolicyRule] = &[];
        static CROSS_DOMAIN_POLICIES: &[CrossDomainPolicyRule] = &[];
        static QUERIES: &[crate::kernel::QueryDef] = &[];

        let tables = Tables {
            policies: POLICIES,
            cross_domain_policies: CROSS_DOMAIN_POLICIES,
            process_managers: PROCESS_MANAGERS,
            reference_key_fn: multi_leg_no_reference_key,
            queries: QUERIES,
            command_creates_fn: multi_leg_always_creates,
            identity_head_fn: multi_leg_no_identity_head,
            command_attributes_fn: multi_leg_no_declared_attributes,
            entity_identity_head_fn: multi_leg_no_entity_identity_head,
        };

        let mut store = MultiLegTestStore;
        let mut sagas: HashMap<(String, String), SagaInstance> = HashMap::new();
        let mut all_events = Vec::new();
        let mut mutations = Vec::new();
        let mut cross_domain = Vec::new();
        let mut reaction_log = Vec::new();
        let mut saga_log: Vec<Json> = Vec::new();

        let outcome = orchestrate(
            &mut store,
            two_leg_test_dispatch,
            tables,
            &mut sagas,
            "Test::Post",
            &Json::Object(vec![]),
            None,
            None,
            None,
            None,
            0,
            &mut all_events,
            &mut mutations,
            &mut cross_domain,
            &mut reaction_log,
            &mut saga_log,
        );
        assert!(outcome.is_ok(), "Post should not refuse: {outcome:?}");

        let advances: Vec<(String, String)> = saga_log
            .iter()
            .filter_map(|entry| {
                if !matches!(entry.get("advanced"), Some(Json::Bool(true))) {
                    return None;
                }
                Some((
                    entry.get("from").and_then(Json::as_str).unwrap_or("").to_string(),
                    entry.get("to").and_then(Json::as_str).unwrap_or("").to_string(),
                ))
            })
            .collect();
        assert_eq!(
            advances,
            vec![("posted".to_string(), "picked_up".to_string()), ("picked_up".to_string(), "handed_over".to_string())],
            "the second Scanned must reach the second leg, not re-find the first — saga_log was: {saga_log:?}"
        );
        assert!(
            all_events.iter().any(|e| e.name == "Delivered"),
            "the second leg's own dispatch must have run — events were: {all_events:?}"
        );
        assert!(
            !sagas.contains_key(&("Delivery".to_string(), "p1".to_string())),
            "Delivered is ends_on — the instance should have been retired"
        );
    }

    // One dispatch announces two events: a saga leg answers the first, a policy the second. The
    // whole batch is logged before any reaction, then reactions run per event in emits order.
    fn two_event_test_dispatch(
        _store: &mut MultiLegTestStore,
        verb: &str,
        _args: &Json,
        _caller_role: Option<&str>,
        _caller_actor_id: Option<&str>,
        _mutations: &mut Vec<MutationRecord>,
    ) -> Result<Vec<Event>, Refusal> {
        let event = |name: &str| Event {
            name: name.to_string(),
            aggregate: "Test::Run".to_string(),
            id: "r1".to_string(),
            payload: Json::obj(vec![("id", Json::str("r1"))]),
            occurred_at: None,
            correlation: None,
        };
        match verb {
            "Test::Start" => Ok(vec![event("Started")]),
            "Test::Advance" => Ok(vec![event("Legged"), event("Reported")]),
            "Test::Log" => Ok(vec![event("Logged")]),
            "Test::Note" => Ok(vec![event("Noted")]),
            other => panic!("unexpected verb in two-event ordering test: {other}"),
        }
    }

    #[test]
    fn a_batch_is_logged_whole_then_reacted_to_per_event_policies_before_sagas() {
        static HANDLERS: &[Handler] = &[Handler {
            event_type: "Legged",
            from_state: "started",
            to_state: "logged",
            dispatches: &[DispatchSpec { command_name: "Log", with: &[], compensates: None }],
        }];
        static PROCESS_MANAGERS: &[ProcessManagerDef] = &[ProcessManagerDef {
            name: "Route",
            correlates_by: "id",
            starts_on: "Started",
            ends_on: "Logged",
            initial_state: "started",
            handlers: HANDLERS,
        }];
        static POLICIES: &[PolicyRule] = &[PolicyRule {
            policy_name: "Audit",
            event_name: "Reported",
            event_qualifier: None,
            target_verb: "Test::Note",
            where_expr: None,
            for_each: None,
            for_each_key: None,
            with_spec: &[],
        }];
        static CROSS_DOMAIN_POLICIES: &[CrossDomainPolicyRule] = &[];
        static QUERIES: &[crate::kernel::QueryDef] = &[];

        let tables = Tables {
            policies: POLICIES,
            cross_domain_policies: CROSS_DOMAIN_POLICIES,
            process_managers: PROCESS_MANAGERS,
            reference_key_fn: multi_leg_no_reference_key,
            queries: QUERIES,
            command_creates_fn: multi_leg_always_creates,
            identity_head_fn: multi_leg_no_identity_head,
            command_attributes_fn: multi_leg_no_declared_attributes,
            entity_identity_head_fn: multi_leg_no_entity_identity_head,
        };

        let mut store = MultiLegTestStore;
        let mut sagas: HashMap<(String, String), SagaInstance> = HashMap::new();
        let mut all_events = Vec::new();
        let mut mutations = Vec::new();
        let mut cross_domain = Vec::new();
        let mut reaction_log = Vec::new();
        let mut saga_log: Vec<Json> = Vec::new();

        for verb in ["Test::Start", "Test::Advance"] {
            let outcome = orchestrate(
                &mut store,
                two_event_test_dispatch,
                tables,
                &mut sagas,
                verb,
                &Json::Object(vec![]),
                None,
                None,
                None,
                None,
                0,
                &mut all_events,
                &mut mutations,
                &mut cross_domain,
                &mut reaction_log,
                &mut saga_log,
            );
            assert!(outcome.is_ok(), "{verb} should not refuse: {outcome:?}");
        }

        let names: Vec<&str> = all_events.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(
            names,
            vec!["Started", "Legged", "Reported", "Logged", "Noted"],
            "both announced events precede every reaction, and the first event's saga leg precedes the second \
             event's policy — reaction_log: {reaction_log:?}, saga_log: {saga_log:?}"
        );
    }

    #[test]
    fn a_leg_miss_names_every_from_state_the_event_could_have_answered_from() {
        static HANDLERS: &[Handler] = &[
            Handler { event_type: "Scanned", from_state: "posted", to_state: "picked_up", dispatches: &[] },
            Handler { event_type: "Scanned", from_state: "picked_up", to_state: "handed_over", dispatches: &[] },
        ];
        let pm = ProcessManagerDef {
            name: "Delivery",
            correlates_by: "id",
            starts_on: "Posted",
            ends_on: "Delivered",
            initial_state: "posted",
            handlers: HANDLERS,
        };
        assert_eq!(select_leg(&pm, "Scanned", "picked_up").map(|h| h.to_state), Some("handed_over"));
        assert!(select_leg(&pm, "Scanned", "handed_over").is_none());
        assert_eq!(leg_mismatch(&pm, "Scanned", "handed_over"), "in \"handed_over\", not \"posted\" or \"picked_up\"");
    }
}
