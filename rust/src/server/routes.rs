// [antibody-exempt: rust/src/server/routes.rs — storehouse engine single-domain
//  HTTP dispatch routes. Kernel Rust transport that executes bluebook commands
//  and queries (the /dispatch + /query endpoints + the effect drain) ; it
//  cannot be bluebook vocabulary (it IS the runtime). Permanent engine-surface
//  exemption — Chris chose the registry/permanent path, 2026-06-25.]
//! Single-domain routes — backward-compatible JSON API
//!
//! Routes for a single domain runtime: dispatch commands,
//! query aggregates, read events, list policies.
//!
//! Usage:
//!   POST /dispatch   { "command": "CreatePizza", "attrs": { "name": "M" } }
//!   GET  /aggregates/:name
//!   GET  /aggregates/:name/:id
//!   GET  /events
//!   GET  /policies
//!   GET  /health

use crate::json_helpers::*;
use crate::runtime::acl_readmodel::{self, DoorPosture};
use crate::runtime::{Runtime, RuntimeError, Value};
use std::cell::RefCell;
use std::collections::HashMap;

pub fn route(
    method: &str, path: &str, body: &str,
    bearer: Option<&str>, posture: DoorPosture, rt: &RefCell<Runtime>,
) -> (&'static str, String) {
    let seg: Vec<&str> = path.trim_matches('/').split('/').collect();

    match (method, seg.as_slice()) {
        ("OPTIONS", _) => ("204 No Content", String::new()),

        ("GET", ["health"]) => ("200 OK", r#"{"status":"ok"}"#.into()),

        // Raw introspection — under a GOVERNED door these answer 403
        // wholesale : /domain and /aggregates project the whole domain
        // shape, /events the full event log, /policies the policy chain.
        // Readers enter through aggregate queries (the aggregate IS the
        // conceptual layer). Under an OPEN door they are unchanged.
        ("GET", ["domain"]) | ("GET", ["aggregates"])
        | ("GET", ["events"]) | ("GET", ["policies"])
        | ("GET", ["schema"]) | ("GET", ["schema", _])
            if posture == DoorPosture::Governed =>
        {
            forbidden_introspection(path)
        }

        ("GET", ["domain"]) => {
            let rt = rt.borrow();
            ("200 OK", domain_json(&rt))
        }

        ("POST", ["dispatch"]) => dispatch(body, bearer, posture, rt),

        // Read side — `GET /query/:verb` resolves a read-only query by
        // its snake_case verb (e.g. /query/daily_musing). Lets the blog
        // be read over HTTP, not just written : dispatch is commands,
        // this is queries.
        ("GET", ["query", verb]) => query(verb, bearer, posture, rt),

        // Read side WITH arguments — `POST /query` takes the same body
        // shape as /dispatch (`{"command":"…","attrs":{…}}`) so the served
        // UI encodes commands and queries identically. This is the door the
        // walking skeleton's query cards post to : the GET form above can
        // only run argument-less queries.
        ("POST", ["query"]) => query_post(body, bearer, posture, rt),

        // JSON Schema (draft 2020-12) per command, from the IR
        // (PLAN-json-schema-projection). `/schema` emits every command's
        // schema keyed by FQN ; `/schema/Aggregate.Command` emits one. The
        // served form renders from this ; external clients validate against
        // it. Read-only introspection — no auth gate (same posture as
        // /domain).
        ("GET", ["schema"]) => {
            let all = crate::projection::json_schema::domain_schemas(&rt.borrow().domain);
            ("200 OK", serde_json::to_string(&all).unwrap_or_else(|_| "{}".into()))
        }
        ("GET", ["schema", fqn]) => {
            let all = crate::projection::json_schema::domain_schemas(&rt.borrow().domain);
            match all.get(*fqn) {
                Some(one) => ("200 OK", serde_json::to_string(one).unwrap_or_else(|_| "{}".into())),
                None => ("404 Not Found", format!(r#"{{"error":"no command {}"}}"#, fqn)),
            }
        }

        ("GET", ["aggregates"]) => {
            let rt = rt.borrow();
            ("200 OK", domain_json(&rt))
        }

        ("GET", ["aggregates", name]) => all_records(name, bearer, posture, rt),

        ("GET", ["aggregates", name, id]) => find_record(name, id, bearer, posture, rt),

        ("GET", ["events"]) => {
            let rt = rt.borrow();
            ("200 OK", events_json(&rt))
        }

        ("GET", ["policies"]) => {
            let rt = rt.borrow();
            ("200 OK", policies_json(&rt))
        }

        _ => ("404 Not Found", r#"{"error":"not found"}"#.into()),
    }
}

/// Wholesale 403 for a raw introspection route under a governed door.
fn forbidden_introspection(path: &str) -> (&'static str, String) {
    ("403 Forbidden", format!(
        r#"{{"ok":false,"error":"introspection is closed under a governed door","command":{}}}"#,
        json_str(path)
    ))
}

/// Gate a READ at the HTTP door : stamp the caller principal from the
/// REQUEST (bearer + posture) into a SEPARATE gate_attrs map — never the
/// query params — and run the standing before-gates over the read phrase
/// (the warm-serve is_query recipe). `authorize_entry` is `&mut self` (it
/// records denials as governed Violations), so the mutable borrow is taken
/// HERE and dropped before the caller borrows for the read itself.
/// Deny -> Some(403 response) ; the resident server NEVER exits on a denial.
fn authorize_read(
    rt: &RefCell<Runtime>, phrase: &str, bearer: Option<&str>, posture: DoorPosture,
) -> Option<(&'static str, String)> {
    let mut gate_attrs: HashMap<String, Value> = HashMap::new();
    acl_readmodel::stamp_principal_from_request(&mut gate_attrs, bearer, posture);
    let verdict = rt.borrow_mut().authorize_entry(phrase, &mut gate_attrs);
    match verdict {
        Ok(()) => None,
        Err(e) => Some(("403 Forbidden", format!(
            r#"{{"ok":false,"error":{},"command":{}}}"#,
            json_str(&e.to_string()), json_str(phrase)
        ))),
    }
}

/// `GET /aggregates/:name` — every record of one aggregate. Enters through
/// the aggregate's read surface, so it gates as `<Aggregate>.state` like the
/// by-id read (the cold `state` subcommand precedent).
fn all_records(
    name: &str, bearer: Option<&str>, posture: DoorPosture, rt: &RefCell<Runtime>,
) -> (&'static str, String) {
    if let Some(denied) = authorize_read(rt, &format!("{}.state", name), bearer, posture) {
        return denied;
    }
    let rt = rt.borrow();
    ("200 OK", aggregates_json(&rt, name))
}

/// `GET /aggregates/:name/:id` — one record by id. Gates as
/// `<Aggregate>.state` (the cold `state` subcommand precedent).
fn find_record(
    name: &str, id: &str, bearer: Option<&str>, posture: DoorPosture, rt: &RefCell<Runtime>,
) -> (&'static str, String) {
    if let Some(denied) = authorize_read(rt, &format!("{}.state", name), bearer, posture) {
        return denied;
    }
    let rt = rt.borrow();
    match rt.find(name, id) {
        Some(s) => ("200 OK", format!(
            r#"{{"id":"{}",{}}}"#, s.id, value_map_to_json(&s.fields)
        )),
        None => ("404 Not Found", format!(
            r#"{{"error":"not found","aggregate":"{}","id":"{}"}}"#, name, id
        )),
    }
}

/// Resolve a read-only query by its verb — matched against each
/// aggregate's query names by exact or snake_case form (so `daily_musing`
/// finds the `DailyMusing` query). The read is GATED before it resolves :
/// the phrase is the query's own FQN (`<Context>::<Aggregate>.<snake_verb>`,
/// context falling back to the domain name), mirroring the warm-serve
/// is_query recipe. Returns the query's JSON result.
pub fn query(
    verb: &str, bearer: Option<&str>, posture: DoorPosture, rt: &RefCell<Runtime>,
) -> (&'static str, String) {
    // The raw request path reaches us WITH its query string attached
    // (server/mod.rs takes `parts[1]` verbatim), so `/query/by_category?cat=hand`
    // arrives here as the single segment `by_category?cat=hand`. Split it.
    //
    // This used to be ignored entirely : the verb was matched whole, so an
    // arg-taking query answered `/query/by_category` by running UNFILTERED --
    // a caller asked a narrow question and got every row back, with nothing
    // signalling the filter had been dropped -- while the correctly-formed
    // `?cat=hand` form 404'd, because `by_category?cat=hand` matched no query
    // name. Both halves were wrong, and silently so.
    let (verb, query_string) = match verb.split_once('?') {
        Some((v, qs)) => (v, qs),
        None => (verb, ""),
    };
    let params = parse_query_string(query_string);

    // Resolve the verb under a SHORT immutable borrow, dropped before the
    // gate needs `&mut` (the borrow trap : this fn used to hold rt.borrow()
    // across its whole body ; authorize_entry records Violations, so it
    // needs borrow_mut).
    let target = {
        let rt = rt.borrow();
        rt.domain.aggregates.iter()
            .flat_map(|a| a.queries.iter().map(move |q| (a, q)))
            .find(|(_, q)| q.name == verb || crate::util::snake_case(&q.name) == verb)
            .map(|(a, q)| {
                let ctx = a.context.clone().unwrap_or_else(|| rt.domain.name.clone());
                let phrase = format!(
                    "{}::{}.{}", ctx, a.name, crate::util::snake_case(&q.name)
                );
                (q.name.clone(), phrase)
            })
    };
    let Some((qname, phrase)) = target else {
        return ("404 Not Found", format!(
            r#"{{"error":"unknown query","verb":"{}"}}"#, verb
        ));
    };
    if let Some(denied) = authorize_read(rt, &phrase, bearer, posture) {
        return denied;
    }
    let rt = rt.borrow();
    let result = rt.resolve_query(&qname, &params);
    ("200 OK", result.to_string())
}

/// Parse an HTTP query string (`cat=hand&status=available`) into the plain
/// string params the runtime's where-clause resolver compares against a
/// record's stringified fields — the same shape `query_post` builds from its
/// JSON body, so the GET and POST read doors agree on argument handling.
///
/// Percent-escapes and `+`-as-space are decoded : a query string is the one
/// place a caller cannot avoid encoding (`?cat=hand%20tools`), and leaving it
/// raw would silently filter on the literal `hand%20tools` and match nothing.
fn parse_query_string(qs: &str) -> HashMap<String, String> {
    qs.split('&')
        .filter(|pair| !pair.is_empty())
        .filter_map(|pair| pair.split_once('='))
        .map(|(k, v)| (percent_decode(k), percent_decode(v)))
        .collect()
}

/// Decode `%XX` escapes and `+`-as-space. Invalid escapes pass through
/// verbatim rather than erroring — a malformed filter should return no rows,
/// not fail the read.
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
                match u8::from_str_radix(hex, 16) {
                    Ok(byte) => {
                        out.push(byte);
                        i += 3;
                    }
                    Err(_) => {
                        out.push(bytes[i]);
                        i += 1;
                    }
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// `POST /query` — resolve a read-only query WITH its named arguments.
/// The body is the /dispatch shape (`{"command":"<verb>","attrs":{…}}`) ;
/// the verb is the query's FQN (`<Context>::<Aggregate>.<snake_verb>`) or a
/// bare query name. Resolution + gating is [`crate::embed::gated_query`] —
/// the SAME core both CLI read doors use, never a second query path.
/// The result is the query's own `{aggregate, query, state:[…]}` on admit ;
/// a governance denial answers 403 and an unknown verb 404, both carrying
/// the runtime's own `{ok:false,error}` body.
pub fn query_post(
    body: &str, bearer: Option<&str>, posture: DoorPosture, rt: &RefCell<Runtime>,
) -> (&'static str, String) {
    let (verb, attrs) = parse_dispatch_body(body);
    if verb.is_empty() {
        return ("400 Bad Request", format!(
            r#"{{"ok":false,"error":{}}}"#,
            json_str("missing \"command\" — the body shape is {\"command\":\"Aggregate.query_verb\",\"attrs\":{}}")
        ));
    }
    // Query params are plain strings (the runtime's where-clause resolver
    // compares against the record's stringified fields), so the parsed
    // Values collapse through Display — Str yields the bare text.
    let params: HashMap<String, String> = attrs.iter()
        .map(|(k, v)| (k.clone(), v.to_string()))
        .collect();

    // The principal is derived from the REQUEST through the same two
    // helpers the write door uses — stamp it into a throwaway meta map,
    // then classify. No second notion of "who is calling".
    let mut meta: HashMap<String, Value> = HashMap::new();
    acl_readmodel::stamp_principal_from_request(&mut meta, bearer, posture);
    let principal = acl_readmodel::principal_from_attrs(&meta);

    let result = gated_query_at_door(&mut rt.borrow_mut(), &verb, params, principal);
    let admitted = result.get("ok").and_then(|o| o.as_bool()) != Some(false);
    if admitted {
        return ("200 OK", result.to_string());
    }
    let msg = result.get("error").and_then(|e| e.as_str()).unwrap_or_default();
    let status = if msg.starts_with("unknown query") {
        "404 Not Found"
    } else {
        "403 Forbidden"
    };
    (status, result.to_string())
}

/// `embed::gated_query` is not-wasm (it pulls the std::fs boot substrate
/// in through its module). The wasm worker never serves HTTP, so the
/// door there answers as an unknown verb rather than failing the build.
#[cfg(not(target_arch = "wasm32"))]
fn gated_query_at_door(
    rt: &mut Runtime, verb: &str, params: HashMap<String, String>,
    principal: acl_readmodel::Principal,
) -> serde_json::Value {
    crate::embed::gated_query(rt, verb, params, principal)
}

#[cfg(target_arch = "wasm32")]
fn gated_query_at_door(
    _rt: &mut Runtime, verb: &str, _params: HashMap<String, String>,
    _principal: acl_readmodel::Principal,
) -> serde_json::Value {
    serde_json::json!({ "ok": false, "error": format!("unknown query: {}", verb) })
}

pub fn dispatch(
    body: &str, bearer: Option<&str>, posture: DoorPosture, rt: &RefCell<Runtime>,
) -> (&'static str, String) {
    // The door argues, never swallows — a stray body key ("args" for
    // "attrs", a typo) must 400 with a hint, not silently dispatch an
    // attribute-less command that mints a phantom record.
    let stray: Vec<String> = crate::json_helpers::top_level_keys(body)
        .into_iter()
        .filter(|k| k != "command" && k != "attrs")
        .collect();
    if !stray.is_empty() {
        let hint = if stray.iter().any(|k| k == "args") {
            " — did you mean \\\"attrs\\\"?"
        } else {
            ""
        };
        return (
            "400 Bad Request",
            format!(
                r#"{{"ok":false,"error":"unknown dispatch body key(s): {}. The body shape is {{\"command\":\"Aggregate.Command\",\"attrs\":{{...}}}}{}"}}"#,
                stray.join(", "),
                hint
            ),
        );
    }
    let (cmd, mut attrs) = parse_dispatch_body(body);
    // Stamp the caller principal from the REQUEST onto the dispatch attrs ;
    // rt.dispatch runs the before-gates internally and strips the reserved
    // keys, exactly like the warm-serve command branch.
    acl_readmodel::stamp_principal_from_request(&mut attrs, bearer, posture);
    let mut rt = rt.borrow_mut();
    // Snapshot the event log before dispatch ; everything after this
    // index is the full cascade fired by this command (i527 — the
    // LivingDiagram needs the trace to animate hop-by-hop).
    let pre_count = rt.event_bus.events().len();
    match rt.dispatch(&cmd, attrs) {
        Ok(r) => {
            // Fire any declared effect ports this command emitted (the
            // screenshot_buffer DiskBuffer handler, payment, …) out-of-
            // process to quiescence, so the dev `serve` actually RUNS
            // effects and the cascade below carries their re-entrant
            // verdicts. No-op when there are no pending OutboundEvents.
            rt.drain_outbound_to_quiescence();
            let evt = r.event.as_ref()
                .map(|e| format!(r#","event":"{}""#, e.name))
                .unwrap_or_default();
            let cascade: Vec<String> = rt.event_bus.events()[pre_count..].iter().map(|e| {
                // Causation-tree view — enrich each cascade element with its
                // own lineage id (event_id) and its parent's (causation_id) so
                // the served UI can build the tree client-side from THIS one
                // response : parent = the element whose event_id == this
                // element's causation_id ; root = the originating command's
                // event (no causation_id). Both keys are OMITTED when absent
                // (older events / non-emitting paths), so the panel falls back
                // to a flat list and never crashes.
                let mut extra = String::new();
                if let Some(ref id) = e.event_id {
                    extra.push_str(&format!(r#","event_id":"{}""#, id));
                }
                if let Some(ref cid) = e.causation_id {
                    extra.push_str(&format!(r#","causation_id":"{}""#, cid));
                }
                // The event's reference leaves (member #1, tool #1) so the
                // causation node names the participants, not just the event.
                let refs = rt.event_refs(&e.aggregate_type, &e.data);
                if !refs.is_empty() {
                    let inner: Vec<String> = refs.iter()
                        .map(|(k, v)| format!(r#"{{"name":"{}","id":"{}"}}"#, k, v))
                        .collect();
                    extra.push_str(&format!(r#","refs":[{}]"#, inner.join(",")));
                }
                format!(
                    r#"{{"event":"{}","aggregate_type":"{}","aggregate_id":"{}"{}}}"#,
                    e.name, e.aggregate_type, e.aggregate_id, extra
                )
            }).collect();
            ("200 OK", format!(
                r#"{{"ok":true,"aggregate_type":"{}","aggregate_id":"{}"{},"cascade":[{}]}}"#,
                r.aggregate_type, r.aggregate_id, evt, cascade.join(",")
            ))
        }
        // A denial is 403 with a JSON body (it used to collapse into the
        // generic 422) ; the resident server answers and keeps serving.
        Err(e @ RuntimeError::Unauthorized { .. }) => ("403 Forbidden", format!(
            r#"{{"ok":false,"error":{},"command":{}}}"#,
            json_str(&e.to_string()), json_str(&cmd)
        )),
        Err(e) => ("422 Unprocessable Entity", format!(
            r#"{{"ok":false,"error":"{}"}}"#, e
        )),
    }
}

pub fn domain_json(rt: &Runtime) -> String {
    let aggs: Vec<String> = rt.domain.aggregates.iter().map(|a| {
        let cmds: Vec<String> = a.commands.iter()
            .map(|c| format!(r#""{}""#, c.name)).collect();
        format!(
            r#"{{"name":"{}","description":{},"commands":[{}]}}"#,
            a.name, json_str(a.description.as_deref().unwrap_or("")),
            cmds.join(",")
        )
    }).collect();
    format!(r#"{{"name":"{}","aggregates":[{}]}}"#, rt.domain.name, aggs.join(","))
}

pub fn aggregates_json(rt: &Runtime, name: &str) -> String {
    let items = rt.all(name);
    let rows: Vec<String> = items.iter().map(|s|
        format!(r#"{{"id":"{}",{}}}"#, s.id, value_map_to_json(&s.fields))
    ).collect();
    format!(
        r#"{{"aggregate":"{}","count":{},"records":[{}]}}"#,
        name, rows.len(), rows.join(",")
    )
}

pub fn events_json(rt: &Runtime) -> String {
    let evts: Vec<String> = rt.event_bus.events().iter().map(|e|
        format!(
            r#"{{"name":"{}","aggregate_type":"{}","aggregate_id":"{}"}}"#,
            e.name, e.aggregate_type, e.aggregate_id
        )
    ).collect();
    format!(r#"{{"count":{},"events":[{}]}}"#, evts.len(), evts.join(","))
}

pub fn policies_json(rt: &Runtime) -> String {
    let pols: Vec<String> = rt.policy_engine.bindings().iter().map(|b|
        format!(
            r#"{{"name":"{}","on_event":"{}","trigger_command":"{}"}}"#,
            b.name, b.on_event, b.trigger_command
        )
    ).collect();
    format!(r#"{{"count":{},"policies":[{}]}}"#, pols.len(), pols.join(","))
}
