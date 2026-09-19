// THE CONSOLE'S `/api/*` SURFACE, IN THIS HOST — the JSON contract
// embryonaut_console's `web/app.rb` serves (its `/api/me`,
// `/api/presentation`, `/api/ui-schema`, `/api/schema`, `/api/:coll`
// routes), answered by the Rust Lambda that actually serves that app
// in production now (`web "Rust"`, web.rs).
//
// WHY THIS EXISTS AT ALL — the deployed host already refuses an
// unauthenticated `/api/...` request exactly the way the Ruby engine
// does (web.rs's `auth_gate`, PR #728: 401 + `{"error":
// "Unauthenticated","message":"sign in first"}`), but an AUTHENTICATED
// one fell straight through to this host's own `/<Domain>/<aggregate>`
// router and came back `404 no domain "api" loaded`. The refusal
// contract matched and the success contract didn't. This module is the
// success contract.
//
// SHAPES ARE THE RUBY ENGINE'S, KEY FOR KEY. Every response body here
// is what `app.rb`'s own `json(...)` would have produced for the same
// request — compact (never pretty-printed, unlike this host's own
// `/<Domain>/<aggregate>` JSON, which has no Ruby counterpart to agree
// with), the same error envelope (`{"error": ..., "message": ...}`),
// the same status codes. A client cannot tell which runtime answered,
// which is the whole point: index.html is served unchanged.
//
// ROUTING IS FLAT AND EXHAUSTIVE. `web::route` hands this module every
// path under `/api/`, and this module answers all of them — an
// unmatched one included, as a JSON 404 rather than by falling through
// to a renderer that would answer HTML. Sinatra's own unmatched-route
// 404 carries its default HTML page with a `json` content type (its
// `before` filter sets the header, its 404 handler doesn't); a JSON
// body is the honest version of the same status, and no client reads
// that body.

use crate::auth::Session;
use crate::dispatch;
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use crate::presentation;
use crate::presentation_write;
use crate::ui_schema;
use crate::web::{percent_decode, respond};
use serde_json::{json, Map, Value};
use std::cmp::Ordering;
use std::collections::HashMap;
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

/// Every `/api/...` request, answered. `session` is always `Some` in
/// production — `web::route` runs `auth_gate` first, which refuses an
/// unauthenticated JSON request with the Ruby engine's own 401 before
/// this module is reached — but it is threaded through rather than
/// unwrapped, because `/api/me` is precisely the route whose Ruby
/// counterpart (`json(session[:member] || {})`) also has an
/// empty-session branch.
#[allow(clippy::too_many_arguments)]
pub async fn route(
    domain_ir: &Value,
    method: &str,
    path: &str,
    query: &HashMap<String, String>,
    raw_body: &str,
    session: Option<&Session>,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    match (method, path) {
        ("GET", "/api/me") => ok(&me(session)),

        // THE WHOLE UI, DERIVED — nav, columns, field shapes,
        // transitions, create forms, merged with whatever the config
        // adds. Read fresh every call, same as `/api/presentation`
        // below and for the same reason: a Settings-screen save has to
        // be visible on this app's very next request, not after a
        // restart.
        ("GET", "/api/ui-schema") => match presentation::load(client, wasm_path, config).await {
            Ok(presentation) => ok(&ui_schema::build(domain_ir, &presentation)),
            Err(e) => internal_error(&e.to_string()),
        },

        // EVERY REAL AGGREGATE, ITS REAL LIFECYCLE STATES, EVERY REAL
        // QUERY — a pure structural fact with no presentation opinion
        // in it, which the Settings screen's own list_query picker and
        // the table's live query picker both read.
        ("GET", "/api/schema") => match presentation::load(client, wasm_path, config).await {
            Ok(presentation) => ok(&ui_schema::schema(domain_ir, &presentation)),
            Err(e) => internal_error(&e.to_string()),
        },

        // Read fresh every call, never memoized — a Settings-screen
        // save has to be visible on the very next request, which is
        // the same reason app.rb calls `PresentationConfig.load` per
        // request rather than caching it in a constant.
        ("GET", "/api/presentation") => match presentation::load(client, wasm_path, config).await {
            Ok(presentation) => ok(&presentation),
            Err(e) => internal_error(&e.to_string()),
        },

        ("PUT", "/api/presentation") => {
            presentation_save(domain_ir, raw_body, client, wasm_path, config, invoker).await
        }

        // EVERYTHING ELSE UNDER `/api/` IS A COLLECTION ROUTE —
        // `/api/:coll` and `/api/:coll/:id`, the two the Ruby engine
        // declares LAST, after its own fixed routes, for the same
        // reason they are matched last here: `:coll` would otherwise
        // swallow `me`, `schema` and the rest.
        //
        // SEGMENTS ARE PERCENT-DECODED, unlike this host's own routes:
        // a record id here is routinely an email address or a slug the
        // client sent through `encodeURIComponent`, and Sinatra hands
        // `params[:id]` to the Ruby engine already decoded.
        _ => {
            let segments: Vec<String> = path
                .strip_prefix("/api/")
                .unwrap_or_default()
                .split('/')
                .filter(|s| !s.is_empty())
                .map(percent_decode)
                .collect();

            match (method, segments.as_slice()) {
                ("GET", [collection]) => {
                    collection_index(domain_ir, collection, query, client, wasm_path, config).await
                }
                ("GET", [collection, id]) => record_show(domain_ir, collection, id, client, wasm_path, config).await,
                ("POST", [collection]) => {
                    collection_create(domain_ir, collection, raw_body, client, wasm_path, config, invoker).await
                }
                ("POST", [collection, id, command]) => {
                    command_route(domain_ir, collection, id, command, raw_body, client, wasm_path, config, invoker).await
                }
                _ => not_found(&format!("no API route for {method} {path}")),
            }
        }
    }
}

// ---- /api/:coll, /api/:coll/:id -------------------------------------

/// `GET /api/:coll` — every record, whatever its status: the plain,
/// generic `.all()` every reference picker, cross-lookup and main table
/// fetch relies on.
///
/// `?query=<name>` names one of this aggregate's OWN declared queries
/// and answers with that query's result instead — real domain logic
/// (`Proposal.Open`'s own `where(status: "sent")`), not a second,
/// console-side copy of the same filter. Its arguments come from
/// same-named params. An unknown query name, or a required argument
/// with nothing in params, degrades to `.all()` rather than erroring —
/// the same "config mistake, don't break the page" rule the Ruby
/// engine applies here.
async fn collection_index(
    domain_ir: &Value,
    collection: &str,
    params: &HashMap<String, String>,
    client: &Mutex<Client>,
    wasm_path: &Path,
    lineage: &LineageConfig,
) -> Value {
    let config = match presentation::load(client, wasm_path, lineage).await {
        Ok(config) => config,
        Err(e) => return internal_error(&e.to_string()),
    };
    let aggregate = match resolve_collection(domain_ir, &config, collection) {
        Ok(aggregate) => aggregate,
        Err(refusal) => return refusal,
    };

    let wanted = params.get("query").map(String::as_str).filter(|name| !name.is_empty());
    let named = wanted.and_then(|name| find_query(aggregate, name));
    if let Some(named) = named {
        if let Some(args) = query_args_from_params(aggregate, named, params) {
            return named_query_rows(domain_ir, aggregate, named, args, client, wasm_path).await;
        }
    }

    let mut records = match read_records(domain_ir, aggregate, client, wasm_path).await {
        Ok(records) => records,
        Err(refusal) => return refusal,
    };
    sort_records(&mut records, &resolve_sort(domain_ir, &config, collection, aggregate, params));
    ok(&Value::Array(records.into_iter().map(|(id, state)| with_id(&id, &state)).collect()))
}

/// `GET /api/:coll/:id` — one record's full state, or the Ruby
/// engine's own `Runtime::NotFound` message, verbatim.
async fn record_show(
    domain_ir: &Value,
    collection: &str,
    id: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    lineage: &LineageConfig,
) -> Value {
    let config = match presentation::load(client, wasm_path, lineage).await {
        Ok(config) => config,
        Err(e) => return internal_error(&e.to_string()),
    };
    let aggregate = match resolve_collection(domain_ir, &config, collection) {
        Ok(aggregate) => aggregate,
        Err(refusal) => return refusal,
    };
    let records = match read_records(domain_ir, aggregate, client, wasm_path).await {
        Ok(records) => records,
        Err(refusal) => return refusal,
    };
    match records.into_iter().find(|(record_id, _)| record_id == id) {
        Some((record_id, state)) => ok(&with_id(&record_id, &state)),
        None => not_found(&format!("no {} found for id {:?}", ui_schema::agg_name(aggregate), id)),
    }
}

/// A COLLECTION KEY IS PRESENTATION, NOT DOMAIN — `collections.<Name>.
/// key` renames one (Engagement's own default "engagements" is really
/// "pipeline"), so this resolves through the same `collection_key`
/// `/api/ui-schema` hands the client. An unknown key raises the SAME
/// `Runtime::NotFound` the Ruby engine raises, with its own message,
/// rather than a bespoke refusal nothing branches on.
///
/// NO LIFECYCLE REQUIREMENT — every aggregate has a real repository
/// regardless, which is the bug the Ruby engine's own `collection_map`
/// comment records at length: a `select(&:lifecycle)` here once made
/// every request a lifecycle-less aggregate's nav item issued 404.
fn resolve_collection<'a>(domain_ir: &'a Value, config: &Value, collection: &str) -> Result<&'a Value, Value> {
    ui_schema::aggregates(domain_ir)
        .into_iter()
        .find(|aggregate| ui_schema::collection_key(aggregate, config) == collection)
        .ok_or_else(|| not_found(&format!("no such collection: {collection}")))
}

fn find_query<'a>(aggregate: &'a Value, name: &str) -> Option<&'a Value> {
    aggregate
        .get("queries")
        .and_then(|v| v.as_array())?
        .iter()
        .find(|query| query.get("name").and_then(|v| v.as_str()) == Some(name))
}

/// Every live record of one aggregate, keyed by id — this host's own
/// `instances` read, filtered to one `"Domain::Aggregate#"` prefix.
async fn read_records(
    domain_ir: &Value,
    aggregate: &Value,
    client: &Mutex<Client>,
    wasm_path: &Path,
) -> Result<Vec<(String, Value)>, Value> {
    let result = dispatch::read(client, wasm_path).await.map_err(|e| internal_error(&format!("{e:#}")))?;
    let prefix = format!(
        "{}::{}#",
        domain_ir.get("name").and_then(|v| v.as_str()).unwrap_or(""),
        ui_schema::agg_name(aggregate)
    );
    Ok(result
        .get("instances")
        .and_then(|v| v.as_object())
        .map(|instances| {
            instances
                .iter()
                .filter_map(|(key, state)| key.strip_prefix(&prefix).map(|id| (id.to_string(), state.clone())))
                .collect()
        })
        .unwrap_or_default())
}

/// `Handle#to_h` ends `state.merge(id: @id)` — the record's own
/// already-reduced scalar identity, added beside its real fields.
fn with_id(id: &str, state: &Value) -> Value {
    let mut record = state.clone();
    if let Some(object) = record.as_object_mut() {
        object.insert("id".to_string(), json!(id));
    }
    record
}

async fn named_query_rows(
    domain_ir: &Value,
    aggregate: &Value,
    named: &Value,
    args: Value,
    client: &Mutex<Client>,
    wasm_path: &Path,
) -> Value {
    let question = format!(
        "{}::{}.{}",
        domain_ir.get("name").and_then(|v| v.as_str()).unwrap_or(""),
        ui_schema::agg_name(aggregate),
        named.get("name").and_then(|v| v.as_str()).unwrap_or("")
    );
    let result = match dispatch::query(client, wasm_path, &question, args).await {
        Ok(result) => result,
        Err(e) => return internal_error(&format!("{e:#}")),
    };
    let answered = result.get("queries").and_then(|v| v.as_array()).and_then(|queries| queries.first()).cloned();
    let Some(answered) = answered else {
        return internal_error(&format!("the kernel answered no query step for {question}"));
    };
    match answered.get("rows").filter(|rows| !rows.is_null()) {
        Some(rows) => ok(rows),
        // A REFUSED QUERY, not a missing one — the Ruby engine lets the
        // domain refusal out as a 422 through its own DOMAIN_REFUSALS
        // handler, naming the refusal CLASS. A refused query step also
        // lands in the kernel's own top-level `refusals` array, which
        // carries that class as `kind` — so the whole envelope is the
        // Ruby one, read through the same `domain_refusal` a refused
        // COMMAND goes through.
        None => domain_refusal(&result),
    }
}

/// SAME-NAMED PARAMS, SHAPED THE WAY EACH ARGUMENT ACTUALLY WIRES — a
/// reference or a plain primitive rides bare; a value-object argument
/// wraps in its own single field (never assuming every value object
/// spells that field "value"). Returns `None` — not a partial hash —
/// the moment a REQUIRED argument has nothing in params, so the caller
/// falls back to `.all()` instead of dispatching a query certain to
/// refuse.
fn query_args_from_params(aggregate: &Value, named: &Value, params: &HashMap<String, String>) -> Option<Value> {
    let mut args = Map::new();
    for attribute in named.get("attributes").and_then(|v| v.as_array())? {
        let name = attribute.get("name").and_then(|v| v.as_str()).unwrap_or("");
        let raw = params.get(name).filter(|value| !value.is_empty());
        let Some(raw) = raw else {
            if attribute.get("optional").and_then(|v| v.as_bool()).unwrap_or(false) {
                continue;
            }
            return None;
        };

        let ty = attribute.get("type").and_then(|v| v.as_str()).unwrap_or("");
        let bare = ui_schema::reference_target(ty).is_some() || PRIMITIVES.contains(&ty);
        if bare {
            args.insert(name.to_string(), json!(raw));
            continue;
        }
        let wire_key = value_object_field(aggregate, ty)?;
        args.insert(name.to_string(), json!({ wire_key: raw }));
    }
    Some(Value::Object(args))
}

const PRIMITIVES: &[&str] = &["String", "Integer", "Float", "TrueClass", "FalseClass"];

fn value_object_field(aggregate: &Value, type_name: &str) -> Option<String> {
    let value_object = aggregate
        .get("value_objects")
        .and_then(|v| v.as_array())?
        .iter()
        .find(|v| v.get("name").and_then(|n| n.as_str()) == Some(type_name))?;
    let first = value_object.get("attributes").and_then(|v| v.as_array())?.first()?;
    first.get("name").and_then(|v| v.as_str()).map(String::from)
}

// ---- POST /api/:coll, POST /api/:coll/:id/:command -------------------

/// `POST /api/:coll` — the aggregate's ONE creating command, with the
/// two things the console does around it that the domain itself
/// cannot: minting an identity nobody should be asked to type
/// (`apply_identity!`), and checking a precondition a creating
/// command's own `given` has no way to express, because a `given` can
/// only read its own aggregate (`check_preconditions!`). Both are
/// config, not code — the same `collections.<Name>.identity` /
/// `.preconditions` entries `/api/ui-schema` already tells the client
/// about, so the picker only offers what the server will accept.
#[allow(clippy::too_many_arguments)]
async fn collection_create(
    domain_ir: &Value,
    collection: &str,
    raw_body: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let presentation = match presentation::load(client, wasm_path, config).await {
        Ok(presentation) => presentation,
        Err(e) => return internal_error(&e.to_string()),
    };
    let aggregate = match resolve_collection(domain_ir, &presentation, collection) {
        Ok(aggregate) => aggregate,
        Err(refusal) => return refusal,
    };
    let mut args = match parsed_body(raw_body) {
        Ok(args) => args,
        Err(refusal) => return refusal,
    };
    let name = ui_schema::agg_name(aggregate);
    let Some(creating) = ui_schema::commands(aggregate).into_iter().find(|c| ui_schema::creates(c)) else {
        return not_found(&format!("{name} declares no creating command"));
    };

    let records = match read_records(domain_ir, aggregate, client, wasm_path).await {
        Ok(records) => records,
        Err(refusal) => return refusal,
    };
    if let Err(refusal) = apply_identity(&presentation, aggregate, &mut args, records.len()) {
        return refusal;
    }
    if let Err(refusal) = check_preconditions(domain_ir, &presentation, aggregate, &args, client, wasm_path).await {
        return refusal;
    }

    let verb = format!("{}::{name}.{}", domain_name(domain_ir), command_name(creating));
    let outcome = match dispatch::handle_facts(client, wasm_path, &verb, args, None, config, invoker).await {
        Ok(outcome) => outcome,
        Err(e) => return internal_error(&format!("{e:#}")),
    };
    if !outcome.accepted {
        return domain_refusal(&outcome.result);
    }
    // The id this call's OWN command targeted — the first mutation of
    // the last step, never whichever mutation happens to sit last
    // there (a policy or saga firing as a side effect pushes further
    // mutations onto the same step). Same rule web.rs's own
    // `own_command_target_id` follows, and for the same bug.
    let id = created_id(&outcome.result).unwrap_or_default();
    created_record(domain_ir, aggregate, &outcome.result, &id)
}

/// `POST /api/:coll/:id/:command` — a mutating (or state-independent
/// — `Contract.Revise`, `RecurringPayment.AdvanceCycle`) command
/// against an existing record.
///
/// ORDER MATTERS, and it is the Ruby engine's order: find the record
/// first (404 if there is none), then check the command name against
/// what this aggregate can actually dispatch (404 if it can't), then
/// dispatch. A caller that gets both wrong is told about the record
/// first, the same way.
#[allow(clippy::too_many_arguments)]
async fn command_route(
    domain_ir: &Value,
    collection: &str,
    id: &str,
    command: &str,
    raw_body: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let presentation = match presentation::load(client, wasm_path, config).await {
        Ok(presentation) => presentation,
        Err(e) => return internal_error(&e.to_string()),
    };
    let aggregate = match resolve_collection(domain_ir, &presentation, collection) {
        Ok(aggregate) => aggregate,
        Err(refusal) => return refusal,
    };
    let name = ui_schema::agg_name(aggregate);
    let records = match read_records(domain_ir, aggregate, client, wasm_path).await {
        Ok(records) => records,
        Err(refusal) => return refusal,
    };
    if !records.iter().any(|(record_id, _)| record_id == id) {
        return not_found(&format!("no {name} found for id {id:?}"));
    }
    let Some(declared) = dispatchable_command(aggregate, command) else {
        return not_found(&format!("{name} declares no command named {command:?}"));
    };
    let args = match parsed_body(raw_body) {
        Ok(args) => args,
        Err(refusal) => return refusal,
    };

    let verb = format!("{}::{name}.{}", domain_name(domain_ir), command_name(declared));
    let outcome = match dispatch::handle_routed(client, wasm_path, &verb, json!(id), args, None, config, invoker).await {
        Ok(outcome) => outcome,
        Err(e) => return internal_error(&format!("{e:#}")),
    };
    if !outcome.accepted {
        return domain_refusal(&outcome.result);
    }
    created_record(domain_ir, aggregate, &outcome.result, id)
}

/// `JSON_DOOR.validate_command!` — checked against what a `Handle` can
/// actually dispatch, which is every command EXCEPT the creating one
/// (that one lives on the aggregate itself, reached through
/// `POST /api/:coll`). Accepting it here would pass this gate clean
/// and then fail as something far less legible.
///
/// The URL carries the snake_cased command name (`accept`,
/// `advance_cycle`) — the same spelling `/api/ui-schema` hands the
/// client in every transition's own `command:` — so the match is
/// against `Naming.snake` of each declared name, never the declared
/// name itself.
fn dispatchable_command<'a>(aggregate: &'a Value, wanted: &str) -> Option<&'a Value> {
    ui_schema::commands(aggregate)
        .into_iter()
        .filter(|command| !ui_schema::creates(command))
        .find(|command| ui_schema::snake(command_name(command)) == wanted)
}

fn command_name(command: &Value) -> &str {
    command.get("name").and_then(|v| v.as_str()).unwrap_or("")
}

fn domain_name(domain_ir: &Value) -> &str {
    domain_ir.get("name").and_then(|v| v.as_str()).unwrap_or("")
}

/// `parsed_body` — an empty body is an empty argument hash (a
/// no-argument command posts nothing), and anything that isn't JSON
/// refuses the way the Ruby engine refuses it.
///
/// A body that parses but isn't an OBJECT refuses the same way. Ruby
/// reaches `public_send(command, **args)` with it and dies of a
/// TypeError — a 500 whose message is about Ruby, not about the
/// request; this names the real problem at the status code that
/// describes it.
fn parsed_body(raw: &str) -> Result<Value, Value> {
    if raw.trim().is_empty() {
        return Ok(json!({}));
    }
    match serde_json::from_str::<Value>(raw) {
        Ok(Value::Object(body)) => Ok(Value::Object(body)),
        _ => Err(refusal(400, "MalformedBody", "request body is not valid JSON")),
    }
}

/// The command's own target id: the FIRST mutation of the LAST step.
fn created_id(result: &Value) -> Option<String> {
    result
        .get("mutations")?
        .as_array()?
        .last()?
        .as_array()?
        .first()?
        .get("id")?
        .as_str()
        .map(String::from)
}

/// The record as it stands after the command — the same materialized
/// shape every read route answers with, read straight out of the
/// kernel's own post-dispatch `instances` rather than re-reading the
/// journal.
fn created_record(domain_ir: &Value, aggregate: &Value, result: &Value, id: &str) -> Value {
    let key = format!("{}::{}#{id}", domain_name(domain_ir), ui_schema::agg_name(aggregate));
    match result.get("instances").and_then(|instances| instances.get(&key)) {
        Some(state) => ok(&with_id(id, state)),
        // Accepted, but this host cannot see the record it just wrote
        // — a real inconsistency, never a 200 with an empty body.
        None => internal_error(&format!("{key} was accepted but is not in the resulting state")),
    }
}

/// A REFUSED COMMAND, IN THE RUBY ENGINE'S OWN ENVELOPE — `422` with
/// `{"error": <refusal class>, "message": <its message>}`. The kernel
/// names the same classes Ruby does (`kind()`: GivenNotMet,
/// InvariantViolation, AlreadyExists, NotFound, Unauthorized …, all of
/// them `Runtime::` classes in `DOMAIN_REFUSALS`), so this envelope is
/// the Ruby one key for key and name for name.
///
/// The LAST refusal, not the first: `dispatch::handle` replays the
/// whole rehydrated history, and every step before this call's own
/// already succeeded once.
fn domain_refusal(result: &Value) -> Value {
    let last = result.get("refusals").and_then(|r| r.as_array()).and_then(|refusals| refusals.last());
    let Some(last) = last else { return refusal(422, "Refused", "the command was refused") };
    refusal(
        422,
        last.get("kind").and_then(|v| v.as_str()).unwrap_or("Refused"),
        last.get("error").and_then(|v| v.as_str()).unwrap_or("the command was refused"),
    )
}

// ---- identity minting ------------------------------------------------

/// A CODE, MINTED — not typed. `collections.<Name>.identity` names one
/// of the creating command's own attributes and how to fill it without
/// asking: `slug` lowercases and hyphenates another submitted field's
/// value (a client's name becomes its reference); `sequence` counts the
/// records already there and mints the next prefixed, zero-padded one
/// (a proposal's number). The hand-written Founder App did this in its
/// own JS, off the browser's already-loaded item count — it happens
/// server-side for the same reason everything else did: one true
/// answer, not one a client has to keep in sync.
///
/// Only fires when the field is genuinely missing. `/api/ui-schema`
/// leaves it out of the create form entirely, but a direct API call
/// that supplies one is left alone rather than overwritten.
fn apply_identity(presentation: &Value, aggregate: &Value, args: &mut Value, existing: usize) -> Result<(), Value> {
    let name = ui_schema::agg_name(aggregate);
    let Some(rule) = presentation.get("collections").and_then(|c| c.get(name)).and_then(|c| c.get("identity")) else {
        return Ok(());
    };
    let Some(field) = rule.get("field").and_then(|v| v.as_str()) else { return Ok(()) };
    if args.get(field).is_some() {
        return Ok(());
    }
    let Some(wire_key) = identity_wire_key(aggregate, field) else { return Ok(()) };

    let minted = match rule.get("strategy").and_then(|v| v.as_str()) {
        Some("slug") => {
            let source = rule.get("source").and_then(|v| v.as_str()).unwrap_or("");
            Some(slugify(&dig_source(args, source)))
        }
        Some("sequence") => {
            let prefix = rule.get("prefix").and_then(|v| v.as_str()).unwrap_or("");
            let pad = rule.get("pad").and_then(|v| v.as_u64()).unwrap_or(3) as usize;
            Some(format!("{prefix}{:0>pad$}", existing + 1))
        }
        // NEITHER MECHANICAL — the `port` strategy delegates to the
        // domain's own `identity_assignment` adapter, a Ruby object
        // this host has no runtime for at all (ADR 0007: rust/host has
        // no port/adapter interpreter and is not getting one). Skipping
        // it silently would dispatch WITHOUT the identity field and
        // surface as a confusing domain refusal about a missing
        // argument; refusing names the real reason.
        Some("port") => {
            return Err(not_implemented(
                "this collection mints its identity through the domain's own identity_assignment port, which this                  host has no adapter runtime to call — create through the Ruby console engine, or configure a slug                  or sequence strategy instead",
            ))
        }
        _ => None,
    };
    let Some(minted) = minted.filter(|value| !value.is_empty()) else { return Ok(()) };
    if let Some(object) = args.as_object_mut() {
        object.insert(field.to_string(), json!({ wire_key: minted }));
    }
    Ok(())
}

/// The wire key an identity value has to be wrapped in — whatever the
/// target value object's own single attribute is actually called. This
/// domain always spells it "value"; nothing here assumes that.
fn identity_wire_key(aggregate: &Value, field: &str) -> Option<String> {
    let attribute = ui_schema::find_attribute(aggregate, field)?;
    let ty = attribute.get("type").and_then(|v| v.as_str())?;
    if ui_schema::reference_target(ty).is_some() {
        return None;
    }
    value_object_field(aggregate, ty)
}

fn dig_source(args: &Value, source: &str) -> String {
    match args.get(source) {
        Some(Value::Object(fields)) => fields.values().next().map(scalar_to_string).unwrap_or_default(),
        Some(value) => scalar_to_string(value),
        None => String::new(),
    }
}

fn scalar_to_string(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// `slugify` — lowercase, every run of non-alphanumerics to a single
/// hyphen, trimmed, and never empty (an unsluggable source becomes
/// "record" rather than an identity of no characters at all).
fn slugify(text: &str) -> String {
    let mut slug = String::new();
    for character in text.trim().to_lowercase().chars() {
        if character.is_ascii_alphanumeric() {
            slug.push(character);
        } else if !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let slug = slug.trim_matches('-').to_string();
    if slug.is_empty() {
        "record".to_string()
    } else {
        slug
    }
}

// ---- preconditions ---------------------------------------------------

/// WHERE "always via a demoed Engagement / an accepted Proposal" STOPS
/// BEING A COMMENT — except it is DATA (`collections.<Name>.
/// preconditions`), not a hand-written table naming one domain's own
/// aggregates. A creating command's own `given` can only read its own
/// aggregate, which is exactly why this lives in the driving adapter
/// rather than the bluebook.
async fn check_preconditions(
    domain_ir: &Value,
    presentation: &Value,
    aggregate: &Value,
    args: &Value,
    client: &Mutex<Client>,
    wasm_path: &Path,
) -> Result<(), Value> {
    let name = ui_schema::agg_name(aggregate);
    let rules = presentation
        .get("collections")
        .and_then(|c| c.get(name))
        .and_then(|c| c.get("preconditions"))
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    if rules.is_empty() {
        return Ok(());
    }

    let instances = dispatch::read(client, wasm_path).await.map_err(|e| internal_error(&format!("{e:#}")))?;
    let instances = instances.get("instances").cloned().unwrap_or_else(|| json!({}));

    for rule in &rules {
        check_precondition(domain_ir, aggregate, rule, args, &instances)?;
    }
    Ok(())
}

fn check_precondition(domain_ir: &Value, aggregate: &Value, rule: &Value, args: &Value, instances: &Value) -> Result<(), Value> {
    let Some(field) = rule.get("field").and_then(|v| v.as_str()) else { return Ok(()) };
    // A missing required reference is the command's own validation to
    // refuse, not this one's.
    let Some(target_id) = args.get(field).and_then(|v| v.as_str()) else { return Ok(()) };
    // Config named a field that isn't a reference at all — caught at
    // save time by the console's own validation, not at dispatch time.
    let Some(target_name) = ui_schema::find_attribute(aggregate, field)
        .and_then(|attribute| attribute.get("type"))
        .and_then(|v| v.as_str())
        .and_then(ui_schema::reference_target)
    else {
        return Ok(());
    };

    let key = format!("{}::{target_name}#{target_id}", domain_name(domain_ir));
    let Some(target) = instances.get(&key) else {
        return Err(precondition_failed(
            rule,
            &format!("no {} with that id", target_name.to_lowercase()),
        ));
    };

    let Some(expected) = rule.get("state").and_then(|v| v.as_str()) else { return Ok(()) };
    let target_aggregate = ui_schema::aggregates(domain_ir).into_iter().find(|a| ui_schema::agg_name(a) == target_name);
    // Config named a state precondition against an aggregate with no
    // lifecycle — again a save-time concern, not a dispatch-time one.
    let Some(state_field) = target_aggregate
        .and_then(|a| a.get("lifecycle").cloned())
        .filter(|l| !l.is_null())
        .and_then(|l| l.get("field").and_then(|v| v.as_str()).map(String::from))
    else {
        return Ok(());
    };

    let actual = target.get(&state_field).and_then(|v| v.as_str()).unwrap_or("");
    if actual == expected {
        return Ok(());
    }
    Err(precondition_failed(rule, &format!("{target_name} is at {actual}, not {expected}")))
}

fn precondition_failed(rule: &Value, derived: &str) -> Value {
    refusal(422, "PreconditionFailed", rule.get("message").and_then(|v| v.as_str()).unwrap_or(derived))
}

// ---- sorting ---------------------------------------------------------

/// The shapes `order_expression` (Ruby's own JSONB-path compiler)
/// already resolves correctly — a plain scalar, the lifecycle field, a
/// single-attribute value object drill, or a value object with one
/// numeric member. Deliberately excluded: `money_sum`/`count`/`rows`/
/// `lines` (a fold over a list) and `reference`/`hop` (a cross-aggregate
/// join). Those stay client-side rather than sorting wrong.
const SQL_SORTABLE_SHAPES: &[&str] = &["text_value", "text", "address", "number", "money", "enum", "pill"];

struct SortSpec {
    field: String,
    descending: bool,
}

/// `?sort=<column key>&direction=asc|desc` — a runtime value, so it is
/// checked against this collection's OWN sortable config (not just
/// "does the field exist") before it can reach the records. Silently
/// ignored, falling back to default order, when the column isn't
/// sortable or its shape can't push to SQL: the client already knows
/// which shapes it sorts locally instead.
fn resolve_sort(
    domain_ir: &Value,
    config: &Value,
    collection: &str,
    aggregate: &Value,
    params: &HashMap<String, String>,
) -> Option<SortSpec> {
    let key = params.get("sort").filter(|key| !key.is_empty())?;
    let schema = ui_schema::build(domain_ir, config);
    let collection_schema = schema.get("collections")?.get(collection)?;
    let column = collection_schema
        .get("columns")?
        .as_array()?
        .iter()
        .find(|column| column.get("key").and_then(|v| v.as_str()) == Some(key.as_str()))?;

    if column.get("sortable") == Some(&json!(false)) {
        return None;
    }
    let shape = column.get("shape").and_then(|v| v.as_str()).unwrap_or("");
    if !SQL_SORTABLE_SHAPES.contains(&shape) {
        return None;
    }

    let field = if key == "__state__" {
        collection_schema.get("stateField")?.as_str()?.to_string()
    } else {
        key.to_string()
    };
    // A column key always names a real attribute by the time it gets
    // here (it matched a field descriptor above), but an aggregate
    // whose own config named something else entirely would otherwise
    // sort by a field no record has — the same check Ruby's own
    // `Postgres#all` makes before it compiles an ORDER BY.
    if ui_schema::find_attribute(aggregate, &field).is_none() && lifecycle_field(aggregate) != Some(field.as_str()) {
        return None;
    }

    Some(SortSpec { field, descending: params.get("direction").map(String::as_str) == Some("desc") })
}

fn lifecycle_field(aggregate: &Value) -> Option<&str> {
    aggregate.get("lifecycle")?.get("field")?.as_str()
}

/// IN MEMORY, NOT IN SQL — this host reads whole aggregates out of the
/// kernel's own `instances` map, so there is no ORDER BY to push into.
/// The ordering itself is Postgres's: ascending by default, NULLS LAST
/// for ascending and NULLS FIRST for descending, and a stable fallback
/// to the record's own id so a tie never reorders between two requests
/// (Ruby's own default `ORDER BY id`, which is also what an unsorted
/// request gets here).
fn sort_records(records: &mut [(String, Value)], spec: &Option<SortSpec>) {
    match spec {
        None => records.sort_by(|(a, _), (b, _)| a.cmp(b)),
        Some(spec) => records.sort_by(|(a_id, a), (b_id, b)| {
            let ordering = compare_sort_keys(sort_key(a, &spec.field), sort_key(b, &spec.field), spec.descending);
            ordering.then_with(|| a_id.cmp(b_id))
        }),
    }
}

/// The scalar a JSONB order path would land on: the field itself when
/// it holds one, the `cents` member of a money-shaped value object, or
/// a single-attribute value object's own sole member.
fn sort_key<'a>(state: &'a Value, field: &str) -> Option<&'a Value> {
    let value = state.get(field).filter(|v| !v.is_null())?;
    let Some(object) = value.as_object() else { return Some(value) };
    if let Some(cents) = object.get("cents") {
        return Some(cents);
    }
    if object.len() == 1 {
        return object.values().next().filter(|v| !v.is_null());
    }
    Some(value)
}

fn compare_sort_keys(left: Option<&Value>, right: Option<&Value>, descending: bool) -> Ordering {
    let ordering = match (left, right) {
        (None, None) => Ordering::Equal,
        // NULLS LAST ascending; reversing below puts them first for
        // descending, which is Postgres's own default pairing.
        (None, Some(_)) => Ordering::Greater,
        (Some(_), None) => Ordering::Less,
        (Some(left), Some(right)) => compare_values(left, right),
    };
    // A null's placement is NOT reversed with the direction — Postgres
    // moves nulls to the front for DESC by keeping the same rule and
    // reversing everything, which is exactly what this does.
    if descending {
        ordering.reverse()
    } else {
        ordering
    }
}

fn compare_values(left: &Value, right: &Value) -> Ordering {
    match (left.as_f64(), right.as_f64()) {
        (Some(left), Some(right)) => left.partial_cmp(&right).unwrap_or(Ordering::Equal),
        _ => left.as_str().unwrap_or("").cmp(right.as_str().unwrap_or("")),
    }
}

/// `GET /api/me` — `json(session[:member] || {})`, and
/// `session[:member]` is exactly what the consuming app's own
/// access-control adapter builds (`session_for`, embryonaut_access_
/// control.rb): `{"email", "name", "identity_id", "role"}`, in that
/// order. This host's own `Session` (auth.rs) already carries those
/// four fields and nothing else, because it was ported from that same
/// adapter — so this is a rename-free projection, not a translation.
///
/// index.html reads `me.name` and `me.role` only, and treats a body
/// with no `name` as "don't render the signed-in banner" — which is
/// what makes `{}` (Ruby's own no-session branch) a real, handled
/// answer rather than a broken one.
fn me(session: Option<&Session>) -> Value {
    let Some(session) = session else { return json!({}) };
    json!({
        "email": session.email,
        "name": session.name,
        "identity_id": session.identity_id,
        "role": session.role,
    })
}

/// `PUT /api/presentation` — `app.rb`'s own `put "/api/presentation"`,
/// contract for contract: the WHOLE config replaced at once, validated
/// against this domain's real live shape before anything is written,
/// and answered with the RELOADED config rather than the submitted one.
///
/// FOUR ANSWERS, EACH ONE THE RUBY ENGINE'S OWN:
///   - 200 with `json(PresentationConfig.load)` on a save.
///   - 400 `MalformedBody` for a body that isn't a JSON object at all —
///     `parsed_body`'s answer everywhere else in this file, and the one
///     case Ruby's own `parsed_body` never reaches because Sinatra has
///     already failed.
///   - 422 `{"error": "Malformed", "message": ...}` for a config that
///     breaks one of `PresentationConfig.validate!`'s rules, message
///     for message.
///   - 422 with the kernel's own `kind`/`error` for a real domain
///     refusal — a tone that got past validation, a row that was never
///     Declared — the same `domain_refusal` shape every dispatching
///     route here uses.
///
/// And one answer that is NOT Ruby's, for a case Ruby cannot be in:
/// 501, unchanged, when this host's kernel carries no ConsoleSettings
/// chapter at all. That is asked of the kernel, never assumed.
#[allow(clippy::too_many_arguments)]
async fn presentation_save(
    domain_ir: &Value,
    raw_body: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let submitted = match parsed_body(raw_body) {
        Ok(submitted) => submitted,
        Err(refusal) => return refusal,
    };

    match presentation_write::save(domain_ir, &submitted, client, wasm_path, config, invoker).await {
        Ok(saved) => ok(&saved),
        Err(presentation_write::SaveRefusal::NoKernel) => not_implemented(PRESENTATION_WRITE_REFUSAL),
        Err(presentation_write::SaveRefusal::Malformed(message)) => refusal(422, "Malformed", &message),
        Err(presentation_write::SaveRefusal::Domain(result)) => domain_refusal(&result),
        Err(presentation_write::SaveRefusal::Internal(message)) => internal_error(&message),
    }
}

// WHAT A HOST WITH NO CONSOLESETTINGS CHAPTER STILL SAYS.
//
// This refusal used to be the whole route, on the premise that this
// crate could never have that chapter: "its `.wasm` kernel is the
// consuming domain's own, and ConsoleSettings has never been compiled
// into it." The second half was wrong. `uses_framework
// "ConsoleSettings"` pulls the chapter into the same registry
// `bin/project_rust` generates from, and `merged.rs` folds its three
// aggregates into the one `Store` the single `.wasm` carries — the
// same way Governance and Identity are already in there, confirmed
// against the real deployed artifact's own strings.
//
// So the route dispatches for real now, and this stays for the case it
// was always truly about: a domain whose kernel genuinely has no such
// chapter. It says which decision is outstanding — attach it — rather
// than 404-ing as if the route had never existed.
const PRESENTATION_WRITE_REFUSAL: &str =
    "this host's kernel carries no ConsoleSettings chapter, so it has no StateStyle/Collection/Overview \
     commands to dispatch, and writing the rows behind its back would skip the invariants those commands \
     enforce. Attach it with `uses_framework \"ConsoleSettings\"` in this domain's own .hecksagon and \
     rebuild the kernel, or save from the Ruby console engine instead.";

// ---- response envelopes — app.rb's own `json`/`halt` shapes ---------

/// `json(data)` — `JSON.generate`, compact.
fn ok(body: &Value) -> Value {
    respond(200, "application/json", &body.to_string())
}

/// Every "that doesn't exist" case in the Ruby engine surfaces as
/// `Runtime::NotFound`, which its own `error` handler renders as a 404
/// with this envelope.
pub(crate) fn not_found(message: &str) -> Value {
    refusal(404, "NotFound", message)
}

/// `error do ... status 500; json({error: "InternalError", ...})` —
/// app.rb's own catch-all.
pub(crate) fn internal_error(message: &str) -> Value {
    refusal(500, "InternalError", message)
}

fn not_implemented(message: &str) -> Value {
    refusal(501, "NotImplemented", message)
}

pub(crate) fn refusal(status: u16, error: &str, message: &str) -> Value {
    respond(status, "application/json", &json!({"error": error, "message": message}).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session() -> Session {
        Session {
            identity_id: "11111111-2222-3333-4444-555555555555".to_string(),
            email: "chris@example.com".to_string(),
            name: "Chris".to_string(),
            role: Some("Admin".to_string()),
        }
    }

    fn body(response: &Value) -> Value {
        serde_json::from_str(response["body"].as_str().expect("a JSON body")).expect("valid JSON")
    }

    // app.rb: `get "/api/me" { json(session[:member] || {}) }`, where
    // session[:member] is embryonaut_access_control.rb's own
    // `{ "email" =>, "name" =>, "identity_id" =>, "role" => }`.
    #[test]
    fn me_is_the_ruby_engines_own_member_hash() {
        assert_eq!(
            me(Some(&session())),
            json!({
                "email": "chris@example.com",
                "name": "Chris",
                "identity_id": "11111111-2222-3333-4444-555555555555",
                "role": "Admin"
            })
        );
    }

    // A Member with a session but no granted role reads `role: null`,
    // not a missing key — Ruby's own hash always carries all four keys
    // (`role` comes back nil when Governance holds no grant and the
    // aggregate's own field is unset).
    #[test]
    fn me_keeps_a_null_role_rather_than_dropping_the_key() {
        let mut session = session();
        session.role = None;
        assert_eq!(me(Some(&session))["role"], Value::Null);
    }

    #[test]
    fn me_with_no_session_is_the_empty_object_ruby_answers() {
        assert_eq!(me(None), json!({}));
    }

    #[test]
    fn an_unknown_api_route_is_a_json_404_not_an_html_one() {
        let response = not_found("no API route for GET /api/nope/nope/nope");
        assert_eq!(response["statusCode"], 404);
        assert_eq!(response["headers"]["content-type"], "application/json");
        assert_eq!(body(&response)["error"], "NotFound");
    }

    // The refusal envelope every non-2xx answer in this module shares,
    // pinned against app.rb's own `json({ error:, message: })`.
    #[test]
    fn a_refusal_carries_exactly_error_and_message() {
        let response = refusal(422, "PreconditionFailed", "the proposal hasn't been accepted yet");
        assert_eq!(response["statusCode"], 422);
        assert_eq!(
            response["body"],
            r#"{"error":"PreconditionFailed","message":"the proposal hasn't been accepted yet"}"#
        );
    }

    // ---- collection routes -----------------------------------------

    fn domain() -> Value {
        json!({
            "name": "EmbryonautFoundersApp",
            "aggregates": [
                {
                    "name": "Client",
                    "identified_by": ["reference.value"],
                    "attributes": [
                        {"name": "reference", "type": "ClientReference", "list": false, "optional": false},
                        {"name": "name", "type": "ClientName", "list": false, "optional": false},
                        {"name": "owner", "type": "Reference<Member>", "list": false, "optional": true},
                        {"name": "fee", "type": "Money", "list": false, "optional": true}
                    ],
                    "value_objects": [
                        {"name": "ClientReference", "attributes": [{"name": "value", "type": "String"}], "closed_set": false, "members": []},
                        {"name": "ClientName", "attributes": [{"name": "value", "type": "String"}], "closed_set": false, "members": []},
                        {"name": "Money", "attributes": [{"name": "cents", "type": "Integer"}, {"name": "currency", "type": "String"}],
                         "closed_set": false, "members": []}
                    ],
                    "entities": [], "commands": [],
                    "queries": [
                        {"name": "Active", "attributes": []},
                        {"name": "ByOwner", "attributes": [{"name": "owner", "type": "Reference<Member>", "list": false, "optional": false}]},
                        {"name": "ByName", "attributes": [{"name": "name", "type": "ClientName", "list": false, "optional": false}]},
                        {"name": "Since", "attributes": [{"name": "year", "type": "Integer", "list": false, "optional": true}]}
                    ],
                    "lifecycle": {"field": "status", "default": "prospect",
                                  "transitions": [{"command": "Activate", "to_state": "active", "from_state": "prospect"}]}
                }
            ]
        })
    }

    fn client_aggregate() -> Value {
        domain()["aggregates"][0].clone()
    }

    fn params(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn a_collection_resolves_through_the_key_the_ui_schema_advertises() {
        let domain = domain();
        assert!(resolve_collection(&domain, &json!({}), "clients").is_ok());

        let renamed = json!({"collections": {"Client": {"key": "accounts"}}});
        assert!(resolve_collection(&domain, &renamed, "accounts").is_ok());
        // The DERIVED key stops working once config renames it — the
        // same single answer `/api/ui-schema` gives the client.
        assert!(resolve_collection(&domain, &renamed, "clients").is_err());
    }

    #[test]
    fn an_unknown_collection_is_the_ruby_engines_own_not_found_message() {
        let refusal = resolve_collection(&domain(), &json!({}), "nope").expect_err("unknown collections refuse");

        assert_eq!(refusal["statusCode"], 404);
        assert_eq!(body(&refusal), json!({"error": "NotFound", "message": "no such collection: nope"}));
    }

    #[test]
    fn a_record_carries_its_id_beside_its_own_fields() {
        assert_eq!(
            with_id("acme", &json!({"name": {"value": "Acme"}})),
            json!({"name": {"value": "Acme"}, "id": "acme"})
        );
    }

    // ---- ?query= ----------------------------------------------------

    #[test]
    fn a_reference_or_primitive_query_argument_rides_bare_and_a_value_object_wraps() {
        let aggregate = client_aggregate();
        let by_owner = find_query(&aggregate, "ByOwner").expect("declared");
        let by_name = find_query(&aggregate, "ByName").expect("declared");

        assert_eq!(
            query_args_from_params(&aggregate, by_owner, &params(&[("owner", "chris@example.com")])),
            Some(json!({"owner": "chris@example.com"}))
        );
        assert_eq!(
            query_args_from_params(&aggregate, by_name, &params(&[("name", "Acme")])),
            Some(json!({"name": {"value": "Acme"}}))
        );
    }

    #[test]
    fn a_missing_required_query_argument_falls_all_the_way_back_to_all_rather_than_dispatching() {
        let aggregate = client_aggregate();
        let by_owner = find_query(&aggregate, "ByOwner").expect("declared");

        assert_eq!(query_args_from_params(&aggregate, by_owner, &params(&[])), None);
        // An EMPTY param is the same as an absent one, matching Ruby's
        // own `raw.nil? || raw.empty?`.
        assert_eq!(query_args_from_params(&aggregate, by_owner, &params(&[("owner", "")])), None);
    }

    #[test]
    fn an_optional_query_argument_is_simply_left_out_when_nothing_supplies_it() {
        let aggregate = client_aggregate();
        let since = find_query(&aggregate, "Since").expect("declared");

        assert_eq!(query_args_from_params(&aggregate, since, &params(&[])), Some(json!({})));
        assert_eq!(query_args_from_params(&aggregate, since, &params(&[("year", "2026")])), Some(json!({"year": "2026"})));
    }

    #[test]
    fn a_no_arg_query_dispatches_with_an_empty_argument_hash() {
        let aggregate = client_aggregate();
        let active = find_query(&aggregate, "Active").expect("declared");

        assert_eq!(query_args_from_params(&aggregate, active, &params(&[])), Some(json!({})));
    }

    #[test]
    fn an_unknown_query_name_is_simply_not_found_so_the_caller_falls_back_to_all() {
        assert!(find_query(&client_aggregate(), "NoSuchQuery").is_none());
    }

    // ---- ?sort= -----------------------------------------------------

    #[test]
    fn a_sortable_column_of_a_pushable_shape_sorts_and_anything_else_falls_back() {
        let domain = domain();
        let aggregate = client_aggregate();
        let spec = resolve_sort(&domain, &json!({}), "clients", &aggregate, &params(&[("sort", "name")]));
        let spec = spec.expect("a text_value column is sortable");
        assert_eq!(spec.field, "name");
        assert!(!spec.descending);

        // A REFERENCE column is deliberately excluded — it would need a
        // cross-aggregate join no order clause wires.
        assert!(resolve_sort(&domain, &json!({}), "clients", &aggregate, &params(&[("sort", "owner")])).is_none());
        // …as is a column config explicitly opts out of.
        let opted_out = json!({"collections": {"Client": {"columns": [{"field": "name", "sortable": false}]}}});
        assert!(resolve_sort(&domain, &opted_out, "clients", &aggregate, &params(&[("sort", "name")])).is_none());
        // …and a column key that isn't in this collection at all.
        assert!(resolve_sort(&domain, &json!({}), "clients", &aggregate, &params(&[("sort", "nope")])).is_none());
    }

    #[test]
    fn sorting_by_the_state_column_sorts_by_whatever_the_lifecycle_field_is_really_called() {
        let domain = domain();
        let aggregate = client_aggregate();
        let spec = resolve_sort(&domain, &json!({}), "clients", &aggregate, &params(&[("sort", "__state__"), ("direction", "desc")]))
            .expect("the derived state pill is sortable");

        assert_eq!(spec.field, "status");
        assert!(spec.descending);
    }

    #[test]
    fn records_sort_by_id_when_nothing_asks_for_an_order() {
        let mut records = vec![
            ("b".to_string(), json!({"name": {"value": "Zed"}})),
            ("a".to_string(), json!({"name": {"value": "Ann"}})),
        ];
        sort_records(&mut records, &None);

        assert_eq!(records.iter().map(|(id, _)| id.as_str()).collect::<Vec<&str>>(), vec!["a", "b"]);
    }

    #[test]
    fn sorting_drills_through_a_single_attribute_value_object_and_through_money_to_its_cents() {
        let mut records = vec![
            ("c".to_string(), json!({"name": {"value": "Cara"}, "fee": {"cents": 300, "currency": "USD"}})),
            ("a".to_string(), json!({"name": {"value": "Ann"}, "fee": {"cents": 1000, "currency": "USD"}})),
        ];

        sort_records(&mut records, &Some(SortSpec { field: "name".to_string(), descending: false }));
        assert_eq!(records[0].0, "a");

        // Money sorts NUMERICALLY by cents — 300 before 1000, which a
        // string comparison would get backwards.
        sort_records(&mut records, &Some(SortSpec { field: "fee".to_string(), descending: false }));
        assert_eq!(records.iter().map(|(id, _)| id.as_str()).collect::<Vec<&str>>(), vec!["c", "a"]);
    }

    #[test]
    fn an_unset_field_sorts_last_ascending_and_first_descending_the_way_postgres_orders_nulls() {
        let mut records = vec![
            ("missing".to_string(), json!({"name": null})),
            ("ann".to_string(), json!({"name": {"value": "Ann"}})),
        ];

        sort_records(&mut records, &Some(SortSpec { field: "name".to_string(), descending: false }));
        assert_eq!(records.iter().map(|(id, _)| id.as_str()).collect::<Vec<&str>>(), vec!["ann", "missing"]);

        sort_records(&mut records, &Some(SortSpec { field: "name".to_string(), descending: true }));
        assert_eq!(records.iter().map(|(id, _)| id.as_str()).collect::<Vec<&str>>(), vec!["missing", "ann"]);
    }

    #[test]
    fn a_record_that_does_not_exist_refuses_with_json_doors_own_wording() {
        // `JSON_DOOR.find!`'s own message, `id` inspected the way Ruby
        // inspects it.
        let refusal = not_found(&format!("no {} found for id {:?}", "Client", "acme"));
        assert_eq!(body(&refusal), json!({"error": "NotFound", "message": "no Client found for id \"acme\""}));
    }

    // ---- write routes ------------------------------------------------

    #[test]
    fn an_empty_body_is_an_empty_argument_hash_and_anything_unparseable_refuses() {
        assert_eq!(parsed_body(""), Ok(json!({})));
        assert_eq!(parsed_body("   "), Ok(json!({})));
        assert_eq!(parsed_body(r#"{"name":{"value":"Acme"}}"#), Ok(json!({"name": {"value": "Acme"}})));

        let refusal = parsed_body("not json").expect_err("a malformed body refuses");
        assert_eq!(refusal["statusCode"], 400);
        assert_eq!(body(&refusal), json!({"error": "MalformedBody", "message": "request body is not valid JSON"}));
        // A body that parses but isn't an object has no arguments to
        // splat — refused the same way rather than dispatched.
        assert!(parsed_body("[1,2,3]").is_err());
    }

    #[test]
    fn a_command_name_matches_the_snake_case_spelling_the_ui_schema_handed_the_client() {
        let aggregate = json!({
            "name": "RecurringPayment",
            "commands": [
                {"name": "Schedule", "references": null, "attributes": []},
                {"name": "AdvanceCycle", "references": "RecurringPayment", "attributes": []}
            ]
        });

        assert_eq!(command_name(dispatchable_command(&aggregate, "advance_cycle").expect("declared")), "AdvanceCycle");
        // The CREATING command is reachable through POST /api/:coll,
        // never here — accepting it would pass this gate and then fail
        // as something far less legible.
        assert!(dispatchable_command(&aggregate, "schedule").is_none());
        assert!(dispatchable_command(&aggregate, "nope").is_none());
    }

    #[test]
    fn a_refused_command_carries_the_kernels_own_refusal_class_and_message() {
        let result = json!({"refusals": [
            {"verb": "X.Y", "error": "an earlier one", "kind": "AlreadyExists"},
            {"verb": "X.Y", "error": "a proposal is only accepted once", "kind": "LifecycleRefused"}
        ]});

        let refusal = domain_refusal(&result);
        assert_eq!(refusal["statusCode"], 422);
        // The LAST refusal — `handle` replays the whole rehydrated
        // history, so everything before this call's own step already
        // succeeded once.
        assert_eq!(
            body(&refusal),
            json!({"error": "LifecycleRefused", "message": "a proposal is only accepted once"})
        );
    }

    #[test]
    fn the_created_id_is_this_commands_own_target_never_a_reactions() {
        let result = json!({"mutations": [
            [{"aggregate": "Client", "id": "earlier"}],
            [{"aggregate": "Proposal", "id": "P-004"}, {"aggregate": "Engagement", "id": "a-policy-fired"}]
        ]});

        assert_eq!(created_id(&result), Some("P-004".to_string()));
    }

    // ---- identity minting --------------------------------------------

    fn client_with_identity(identity: Value) -> (Value, Value) {
        let aggregate = json!({
            "name": "Client",
            "identified_by": ["reference.value"],
            "attributes": [
                {"name": "reference", "type": "ClientReference", "list": false, "optional": false},
                {"name": "name", "type": "ClientName", "list": false, "optional": false},
                {"name": "owner", "type": "Reference<Member>", "list": false, "optional": true}
            ],
            "value_objects": [
                {"name": "ClientReference", "attributes": [{"name": "value", "type": "String"}], "closed_set": false, "members": []},
                {"name": "ClientName", "attributes": [{"name": "value", "type": "String"}], "closed_set": false, "members": []}
            ],
            "entities": [], "commands": [], "queries": [], "lifecycle": null
        });
        let presentation = json!({"collections": {"Client": {"identity": identity}}});
        (aggregate, presentation)
    }

    #[test]
    fn a_slug_identity_is_minted_from_another_submitted_field() {
        let (aggregate, presentation) = client_with_identity(json!({"field": "reference", "strategy": "slug", "source": "name"}));
        let mut args = json!({"name": {"value": "Acme Corp."}});

        apply_identity(&presentation, &aggregate, &mut args, 0).expect("slugging never refuses");

        assert_eq!(args["reference"], json!({"value": "acme-corp"}));
    }

    #[test]
    fn a_sequence_identity_counts_the_records_already_there_and_pads_to_the_configured_width() {
        let (aggregate, presentation) =
            client_with_identity(json!({"field": "reference", "strategy": "sequence", "prefix": "C-", "pad": 4}));
        let mut args = json!({"name": {"value": "Acme"}});

        apply_identity(&presentation, &aggregate, &mut args, 41).expect("sequencing never refuses");

        assert_eq!(args["reference"], json!({"value": "C-0042"}));
    }

    #[test]
    fn an_identity_the_caller_supplied_is_left_exactly_as_it_came() {
        let (aggregate, presentation) = client_with_identity(json!({"field": "reference", "strategy": "slug", "source": "name"}));
        let mut args = json!({"reference": {"value": "chosen-by-hand"}, "name": {"value": "Acme"}});

        apply_identity(&presentation, &aggregate, &mut args, 0).expect("supplied identities never refuse");

        assert_eq!(args["reference"], json!({"value": "chosen-by-hand"}));
    }

    #[test]
    fn an_identity_rule_naming_a_reference_field_mints_nothing_rather_than_guessing_a_wire_shape() {
        let (aggregate, presentation) = client_with_identity(json!({"field": "owner", "strategy": "slug", "source": "name"}));
        let mut args = json!({"name": {"value": "Acme"}});

        apply_identity(&presentation, &aggregate, &mut args, 0).expect("no refusal");

        assert!(args.get("owner").is_none(), "{args}");
    }

    // The one identity strategy this host genuinely cannot run: it
    // delegates to the domain's own identity_assignment ADAPTER, Ruby
    // code this crate has no runtime for. Refusing names the reason;
    // skipping silently would dispatch without the field and surface
    // as a confusing "absent argument" from the kernel.
    #[test]
    fn a_port_identity_strategy_refuses_in_its_own_words_rather_than_dispatching_without_one() {
        let (aggregate, presentation) = client_with_identity(json!({"field": "reference", "strategy": "port"}));
        let mut args = json!({"name": {"value": "Acme"}});

        let refusal = apply_identity(&presentation, &aggregate, &mut args, 0).expect_err("the port strategy refuses");

        assert_eq!(refusal["statusCode"], 501);
        assert!(
            body(&refusal)["message"].as_str().expect("a message").contains("identity_assignment"),
            "{refusal}"
        );
    }

    #[test]
    fn slugify_matches_the_console_engines_own_rules() {
        assert_eq!(slugify("Acme Corp."), "acme-corp");
        assert_eq!(slugify("  Hello,   World!  "), "hello-world");
        assert_eq!(slugify("...."), "record");
        assert_eq!(slugify(""), "record");
    }

    // ---- preconditions ------------------------------------------------

    fn precondition_domain() -> Value {
        json!({
            "name": "EmbryonautFoundersApp",
            "aggregates": [
                {
                    "name": "Contract",
                    "identified_by": ["number.value"],
                    "attributes": [
                        {"name": "number", "type": "ContractNumber", "list": false, "optional": false},
                        {"name": "proposal_id", "type": "Reference<Proposal>", "list": false, "optional": false}
                    ],
                    "value_objects": [{"name": "ContractNumber", "attributes": [{"name": "value", "type": "String"}],
                                       "closed_set": false, "members": []}],
                    "entities": [], "commands": [], "queries": [], "lifecycle": null
                },
                {
                    "name": "Proposal",
                    "identified_by": ["number.value"],
                    "attributes": [], "value_objects": [], "entities": [], "commands": [], "queries": [],
                    "lifecycle": {"field": "status", "default": "drafted", "transitions": []}
                }
            ]
        })
    }

    fn contract() -> Value {
        precondition_domain()["aggregates"][0].clone()
    }

    #[test]
    fn a_precondition_passes_when_the_target_is_already_in_the_named_state() {
        let instances = json!({"EmbryonautFoundersApp::Proposal#P-001": {"status": "accepted"}});
        let rule = json!({"field": "proposal_id", "state": "accepted"});

        assert!(check_precondition(&precondition_domain(), &contract(), &rule, &json!({"proposal_id": "P-001"}), &instances).is_ok());
    }

    #[test]
    fn a_precondition_refuses_when_the_target_is_in_some_other_state() {
        let instances = json!({"EmbryonautFoundersApp::Proposal#P-001": {"status": "sent"}});
        let rule = json!({"field": "proposal_id", "state": "accepted"});

        let refusal = check_precondition(&precondition_domain(), &contract(), &rule, &json!({"proposal_id": "P-001"}), &instances)
            .expect_err("a proposal that isn't accepted refuses");

        assert_eq!(refusal["statusCode"], 422);
        assert_eq!(
            body(&refusal),
            json!({"error": "PreconditionFailed", "message": "Proposal is at sent, not accepted"})
        );
    }

    #[test]
    fn a_precondition_uses_its_own_configured_message_when_it_has_one() {
        let rule = json!({"field": "proposal_id", "state": "accepted", "message": "the proposal hasn't been accepted yet"});
        let instances = json!({"EmbryonautFoundersApp::Proposal#P-001": {"status": "sent"}});

        let refusal = check_precondition(&precondition_domain(), &contract(), &rule, &json!({"proposal_id": "P-001"}), &instances)
            .expect_err("refuses");

        assert_eq!(body(&refusal)["message"], "the proposal hasn't been accepted yet");
    }

    #[test]
    fn a_precondition_refuses_a_reference_to_a_record_that_does_not_exist_at_all() {
        let rule = json!({"field": "proposal_id", "state": "accepted"});

        let refusal = check_precondition(&precondition_domain(), &contract(), &rule, &json!({"proposal_id": "ghost"}), &json!({}))
            .expect_err("refuses");

        assert_eq!(body(&refusal), json!({"error": "PreconditionFailed", "message": "no proposal with that id"}));
    }

    #[test]
    fn a_precondition_says_nothing_about_a_reference_the_caller_left_out() {
        // A missing REQUIRED reference is the command's own validation
        // to refuse, in the domain's own words — not this check's.
        let rule = json!({"field": "proposal_id", "state": "accepted"});

        assert!(check_precondition(&precondition_domain(), &contract(), &rule, &json!({}), &json!({})).is_ok());
    }

    #[test]
    fn a_precondition_naming_a_field_that_is_not_a_reference_simply_does_not_fire() {
        let rule = json!({"field": "number", "state": "accepted"});

        assert!(check_precondition(&precondition_domain(), &contract(), &rule, &json!({"number": "C-001"}), &json!({})).is_ok());
    }

    // ---- both write routes, end to end --------------------------------
    //
    // Everything above this point is a pure decision tested in
    // isolation. This one runs the two POST routes for real: a
    // throwaway Postgres, the real compiled banking kernel, and
    // banking's own generated IR — the same three pieces `dispatch.rs`'s
    // own tests use, reached through its test helpers rather than a
    // second copy of them.
    //
    // The scratch database has no ConsoleSettings relations at all, so
    // the presentation config reads back empty and the collection key
    // is the derived one ("customers") — which is exactly the shape
    // every domain but the one console app is in.

    fn banking_ir() -> Value {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist/banking.ir.json");
        serde_json::from_str(&std::fs::read_to_string(path).expect("bin/project_wasm writes banking.ir.json beside the wasm"))
            .expect("valid IR")
    }

    /// `checkout_fixture` attaches ConsoleSettings the way a real
    /// console app does (`uses_framework "ConsoleSettings"` in its own
    /// `.hecksagon`), so its `.wasm` carries that chapter's kernel —
    /// which is the whole premise of `PUT /api/presentation`. Built by
    /// `bin/project_wasm spec/fixtures/rust_host/checkout_fixture`,
    /// same as `web.rs`'s own checkout routes already use.
    fn console_fixture() -> (std::path::PathBuf, Value) {
        let dist = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist");
        let ir = serde_json::from_str(
            &std::fs::read_to_string(dist.join("checkout_fixture.ir.json"))
                .expect("bin/project_wasm writes checkout_fixture.ir.json beside the wasm"),
        )
        .expect("valid IR");
        (dist.join("checkout_fixture.wasm"), ir)
    }

    /// Every real state styled — `missing_state_entries` refuses a save
    /// that leaves one out, in both engines. `Registration` declares no
    /// lifecycle at all and so has nothing to style, which is exactly
    /// the case that check must not fire on.
    fn every_state_styled() -> Value {
        json!({"states": {"Event": {"open": {"tone": "good"}, "closed": {"tone": "muted"}}}})
    }

    #[tokio::test]
    async fn the_presentation_config_is_saved_and_read_back_through_the_kernels_own_commands() {
        let client = crate::dispatch::tests::scratch_db("rust_host_api_presentation_save").await;
        crate::dispatch::tests::provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "StateStyle", "Collection", "Overview"],
        )
        .await;
        let (wasm, ir) = console_fixture();
        let lineage = LineageConfig { domain: "CheckoutFixture".to_string(), era: Some(1) };
        let invoker = crate::lambda_client::NeverInvoker;

        // Nothing saved yet — every section empty, the same answer the
        // Ruby engine gives a console that has never saved.
        let before = presentation::load(&client, &wasm, &lineage).await.expect("a config");
        assert_eq!(before, json!({"states": {}, "collections": {}, "overview": {}}));

        let mut submitted = every_state_styled();
        submitted["states"]["Event"]["open"] = json!({"tone": "good", "attention": true, "label": "Open for signups"});
        submitted["collections"] = json!({
            "Event": {
                "label": "Sessions",
                "nav_order": 1,
                "columns": ["slug", {"field": "name", "sortable": true, "head": "Title"}, "__state__"],
                "detail_fields": [{"field": "price", "display": "mono"}],
                "field_formats": {"capacity": "percent"},
                "identity": {"field": "slug", "strategy": "slug", "source": "name", "pad": 3},
                "noun_sing": "session"
            }
        });
        submitted["overview"] = json!({"stats": [{"label": "Open", "collection": "events",
                                                  "where": {"state": "open"}}]});

        let saved = presentation_save(&ir, &submitted.to_string(), &client, &wasm, &lineage, &invoker).await;
        assert_eq!(saved["statusCode"], 200, "{saved}");
        let stored = body(&saved);

        // THE RESPONSE IS THE RELOADED CONFIG, not the submitted one —
        // app.rb returns `json(PresentationConfig.load)` after a save.
        assert_eq!(stored["states"]["Event"]["open"]["tone"], "good");
        assert_eq!(stored["states"]["Event"]["open"]["attention"], json!(true));
        // A field this chapter does not model individually still
        // round-trips, through `extra_json`.
        assert_eq!(stored["states"]["Event"]["open"]["label"], "Open for signups");
        assert_eq!(stored["states"]["Event"]["closed"]["tone"], "muted");
        assert!(stored["states"].get("Registration").is_none(), "a lifecycle-less aggregate is styled by nothing");
        assert_eq!(stored["collections"]["Event"]["label"], "Sessions");
        assert_eq!(stored["collections"]["Event"]["nav_order"], json!(1));
        assert_eq!(stored["collections"]["Event"]["noun_sing"], "session");
        assert_eq!(stored["collections"]["Event"]["columns"][1]["sortable"], json!(true));
        assert_eq!(stored["collections"]["Event"]["columns"][1]["head"], "Title");
        assert_eq!(stored["collections"]["Event"]["identity"]["pad"], json!(3));
        assert_eq!(stored["collections"]["Event"]["field_formats"], json!({"capacity": "percent"}));
        assert_eq!(stored["overview"]["stats"][0]["where"], json!({"state": "open"}));

        // …and a FRESH read agrees with the save's own answer, which is
        // what proves the rows are really in the kernel's own store and
        // not just in the response this call happened to build.
        assert_eq!(presentation::load(&client, &wasm, &lineage).await.expect("a config"), stored);

        // SAVING AGAIN IS SAFE — every present field is re-dispatched,
        // and a row that already exists is a `Set*`, never a second
        // `Declare` (which would refuse `AlreadyExists`).
        let again = presentation_save(&ir, &submitted.to_string(), &client, &wasm, &lineage, &invoker).await;
        assert_eq!(again["statusCode"], 200, "{again}");
        assert_eq!(body(&again), stored);
    }

    #[tokio::test]
    async fn a_config_that_breaks_a_rule_refuses_422_malformed_and_writes_nothing() {
        let client = crate::dispatch::tests::scratch_db("rust_host_api_presentation_malformed").await;
        crate::dispatch::tests::provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "StateStyle", "Collection", "Overview"],
        )
        .await;
        let (wasm, ir) = console_fixture();
        let lineage = LineageConfig { domain: "CheckoutFixture".to_string(), era: Some(1) };
        let invoker = crate::lambda_client::NeverInvoker;

        let mut bad = every_state_styled();
        bad["states"]["Event"]["open"] = json!({"tone": "chartreuse"});

        let refused = presentation_save(&ir, &bad.to_string(), &client, &wasm, &lineage, &invoker).await;

        assert_eq!(refused["statusCode"], 422, "{refused}");
        assert_eq!(body(&refused)["error"], "Malformed");
        assert_eq!(
            body(&refused)["message"],
            "Event.open's tone \"chartreuse\" isn't one of good, warn, danger, muted, accent"
        );

        // NOTHING WRITTEN — `validate` runs before the first dispatch,
        // which is the whole reason it is a separate pass.
        assert_eq!(
            presentation::load(&client, &wasm, &lineage).await.expect("a config"),
            json!({"states": {}, "collections": {}, "overview": {}})
        );
    }

    #[tokio::test]
    async fn a_body_that_is_not_json_at_all_is_a_400_before_anything_is_validated() {
        let client = crate::dispatch::tests::scratch_db("rust_host_api_presentation_bad_body").await;
        crate::dispatch::tests::provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event"]).await;
        let (wasm, ir) = console_fixture();
        let lineage = LineageConfig { domain: "CheckoutFixture".to_string(), era: Some(1) };

        let refused = presentation_save(
            &ir,
            "not json",
            &client,
            &wasm,
            &lineage,
            &crate::lambda_client::NeverInvoker,
        )
        .await;

        assert_eq!(refused["statusCode"], 400, "{refused}");
        assert_eq!(body(&refused)["error"], "MalformedBody");
    }

    /// The old 501, still the answer for the case it was always really
    /// about: banking's kernel carries no ConsoleSettings chapter, and
    /// this ASKS it rather than inferring it from anything else.
    #[tokio::test]
    async fn a_host_whose_kernel_has_no_console_settings_chapter_still_refuses_501() {
        let client = crate::dispatch::tests::scratch_db("rust_host_api_presentation_no_chapter").await;
        crate::dispatch::tests::provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let wasm = crate::dispatch::tests::wasm_path();
        let ir = banking_ir();
        let lineage = LineageConfig { domain: "Banking".to_string(), era: Some(1) };

        let refused = presentation_save(
            &ir,
            r#"{"states":{}}"#,
            &client,
            &wasm,
            &lineage,
            &crate::lambda_client::NeverInvoker,
        )
        .await;

        assert_eq!(refused["statusCode"], 501, "{refused}");
        assert_eq!(body(&refused)["error"], "NotImplemented");
        assert!(
            body(&refused)["message"].as_str().expect("a message").contains("ConsoleSettings"),
            "the refusal has to name what is missing: {refused}"
        );
    }

    #[tokio::test]
    async fn a_record_is_created_then_commanded_then_read_back_through_the_api_routes() {
        let client = crate::dispatch::tests::scratch_db("rust_host_api_write_routes").await;
        crate::dispatch::tests::provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let wasm = crate::dispatch::tests::wasm_path();
        let ir = banking_ir();
        let lineage = LineageConfig { domain: "Banking".to_string(), era: Some(1) };
        let invoker = crate::lambda_client::NeverInvoker;

        let created = collection_create(
            &ir,
            "customers",
            r#"{"reference":{"value":"CUST-9001"},"name":{"given":"Ada","family":"Lovelace"},"email":{"address":"ada@example.com"}}"#,
            &client,
            &wasm,
            &lineage,
            &invoker,
        )
        .await;

        assert_eq!(created["statusCode"], 200, "{created}");
        let record = body(&created);
        assert_eq!(record["id"], "CUST-9001");
        assert_eq!(record["reference"]["value"], "CUST-9001");

        // …and it is there to read, both ways.
        let index = collection_index(&ir, "customers", &params(&[]), &client, &wasm, &lineage).await;
        assert_eq!(body(&index).as_array().expect("an array").len(), 1);
        let shown = record_show(&ir, "customers", "CUST-9001", &client, &wasm, &lineage).await;
        assert_eq!(body(&shown)["id"], "CUST-9001");

        // A command against it, named the snake_case way
        // /api/ui-schema hands it to the client.
        let suspended = command_route(
            &ir,
            "customers",
            "CUST-9001",
            "suspend",
            r#"{"standing":{"value":"watch"}}"#,
            &client,
            &wasm,
            &lineage,
            &invoker,
        )
        .await;

        assert_eq!(suspended["statusCode"], 200, "{suspended}");
        assert_eq!(body(&suspended)["status"], "suspended");

        // The SAME command again is a real domain refusal — 422 in the
        // Ruby engine's envelope, carrying the kernel's own refusal
        // class, not a generic error.
        let again = command_route(
            &ir,
            "customers",
            "CUST-9001",
            "suspend",
            r#"{"standing":{"value":"watch"}}"#,
            &client,
            &wasm,
            &lineage,
            &invoker,
        )
        .await;

        assert_eq!(again["statusCode"], 422, "{again}");
        let refused = body(&again);
        assert!(!refused["error"].as_str().expect("a refusal class").is_empty(), "{refused}");
        assert!(!refused["message"].as_str().expect("a message").is_empty(), "{refused}");

        // An unknown command, and an unknown record, both refuse the
        // way JsonDoor refuses them.
        let unknown_command =
            command_route(&ir, "customers", "CUST-9001", "nope", "", &client, &wasm, &lineage, &invoker).await;
        assert_eq!(unknown_command["statusCode"], 404);
        assert_eq!(body(&unknown_command)["message"], "Customer declares no command named \"nope\"");

        let unknown_record =
            command_route(&ir, "customers", "ghost", "suspend", "", &client, &wasm, &lineage, &invoker).await;
        assert_eq!(unknown_record["statusCode"], 404);
        assert_eq!(body(&unknown_record)["message"], "no Customer found for id \"ghost\"");
    }

    #[test]
    fn the_presentation_write_route_refuses_in_its_own_words() {
        let response = not_implemented(PRESENTATION_WRITE_REFUSAL);
        assert_eq!(response["statusCode"], 501);
        assert_eq!(body(&response)["error"], "NotImplemented");
        assert!(
            body(&response)["message"].as_str().expect("a message").contains("ConsoleSettings"),
            "the refusal has to name what is missing: {response}"
        );
    }
}
