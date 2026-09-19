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
use crate::presentation;
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
    session: Option<&Session>,
    client: &Mutex<Client>,
    wasm_path: &Path,
) -> Value {
    match (method, path) {
        ("GET", "/api/me") => ok(&me(session)),

        // THE WHOLE UI, DERIVED — nav, columns, field shapes,
        // transitions, create forms, merged with whatever the config
        // adds. Read fresh every call, same as `/api/presentation`
        // below and for the same reason: a Settings-screen save has to
        // be visible on this app's very next request, not after a
        // restart.
        ("GET", "/api/ui-schema") => match presentation::load(client).await {
            Ok(config) => ok(&ui_schema::build(domain_ir, &config)),
            Err(e) => internal_error(&e.to_string()),
        },

        // EVERY REAL AGGREGATE, ITS REAL LIFECYCLE STATES, EVERY REAL
        // QUERY — a pure structural fact with no presentation opinion
        // in it, which the Settings screen's own list_query picker and
        // the table's live query picker both read.
        ("GET", "/api/schema") => match presentation::load(client).await {
            Ok(config) => ok(&ui_schema::schema(domain_ir, &config)),
            Err(e) => internal_error(&e.to_string()),
        },

        // Read fresh every call, never memoized — a Settings-screen
        // save has to be visible on the very next request, which is
        // the same reason app.rb calls `PresentationConfig.load` per
        // request rather than caching it in a constant.
        ("GET", "/api/presentation") => match presentation::load(client).await {
            Ok(config) => ok(&config),
            Err(e) => internal_error(&e.to_string()),
        },

        ("PUT", "/api/presentation") => not_implemented(PRESENTATION_WRITE_REFUSAL),

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
                ("GET", [collection]) => collection_index(domain_ir, collection, query, client, wasm_path).await,
                ("GET", [collection, id]) => record_show(domain_ir, collection, id, client, wasm_path).await,
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
) -> Value {
    let config = match presentation::load(client).await {
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
async fn record_show(domain_ir: &Value, collection: &str, id: &str, client: &Mutex<Client>, wasm_path: &Path) -> Value {
    let config = match presentation::load(client).await {
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
    let answered = result.get("queries").and_then(|v| v.as_array()).and_then(|queries| queries.first());
    let Some(answered) = answered else {
        return internal_error(&format!("the kernel answered no query step for {question}"));
    };
    match answered.get("rows").filter(|rows| !rows.is_null()) {
        Some(rows) => ok(rows),
        // A REFUSED QUERY, not a missing one — the Ruby engine lets the
        // domain refusal out as a 422 through its own DOMAIN_REFUSALS
        // handler, which names the refusal CLASS. The kernel reports a
        // refusal as a message string only (cli.rs keeps
        // `refusal.to_string()`), so the class name is the one part of
        // that envelope this host cannot reproduce; the status and the
        // message are the Ruby engine's own.
        None => refusal(
            422,
            "Refused",
            answered.get("error").and_then(|v| v.as_str()).unwrap_or("the query was refused"),
        ),
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

// PUT /api/presentation IS DELIBERATELY NOT PORTED, AND SAYS SO.
//
// The Ruby engine's write path (`PresentationConfig.save!`) validates
// the whole submitted config against the live domain IR and then
// dispatches a dozen real `ConsoleSettings::*` commands — Declare,
// SetTone, SetAttention, ReplaceColumns, ReplaceDetailFields,
// ReplacePreconditions, ReplaceStats — through a runtime that has that
// chapter booted. This host does not have it booted and cannot: its
// `.wasm` kernel is the consuming domain's own, and ConsoleSettings
// has never been compiled into it (the consuming app pins that chapter
// to Ruby's Postgres adapter permanently — see presentation.rs's own
// header for why, in the app's own words).
//
// So the write would have to be one of: (a) hand-rolled SQL appending
// to Ruby's era journal and upserting its head snapshot, with the
// aggregate's own invariants — `tone` is a `one_of`, a state must be
// Declared before it is styled — simply not run; (b) a second store
// (S3, a config table) that Ruby's own console would then not read,
// splitting one config in two; or (c) compiling ConsoleSettings into
// this domain's kernel and migrating the existing rows into this
// crate's flat journal, which is a real deployment decision with a
// data migration attached, not a code change.
//
// (a) and (b) are both "write it somewhere and hope" — this file
// refuses instead. The READ path above is complete and live, so every
// console screen that only READS presentation config works here
// today; only the Settings screen's save does not, and it says which
// of the three decisions is outstanding rather than 404-ing as if the
// route had never existed.
const PRESENTATION_WRITE_REFUSAL: &str =
    "this host serves the console's presentation config read-only: it has no ConsoleSettings kernel to \
     dispatch StateStyle/Collection/Overview commands through, and writing the rows behind its back would \
     skip the invariants those commands enforce. Save from the Ruby console engine, or decide to move \
     ConsoleSettings into this domain's own kernel.";

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
