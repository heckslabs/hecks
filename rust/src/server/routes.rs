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
    let result = rt.resolve_query(&qname, &std::collections::HashMap::new());
    ("200 OK", result.to_string())
}

pub fn dispatch(
    body: &str, bearer: Option<&str>, posture: DoorPosture, rt: &RefCell<Runtime>,
) -> (&'static str, String) {
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
