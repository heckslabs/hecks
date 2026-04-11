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
use crate::runtime::Runtime;
use std::cell::RefCell;

pub fn route(
    method: &str, path: &str, body: &str, rt: &RefCell<Runtime>,
) -> (&'static str, String) {
    let seg: Vec<&str> = path.trim_matches('/').split('/').collect();

    match (method, seg.as_slice()) {
        ("OPTIONS", _) => ("204 No Content", String::new()),

        ("GET", ["health"]) => ("200 OK", r#"{"status":"ok"}"#.into()),

        ("GET", ["domain"]) => {
            let rt = rt.borrow();
            ("200 OK", domain_json(&rt))
        }

        ("POST", ["dispatch"]) => dispatch(body, rt),

        ("GET", ["aggregates"]) => {
            let rt = rt.borrow();
            ("200 OK", domain_json(&rt))
        }

        ("GET", ["aggregates", name]) => {
            let rt = rt.borrow();
            ("200 OK", aggregates_json(&rt, name))
        }

        ("GET", ["aggregates", name, id]) => {
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

pub fn dispatch(body: &str, rt: &RefCell<Runtime>) -> (&'static str, String) {
    let (cmd, attrs) = parse_dispatch_body(body);
    let mut rt = rt.borrow_mut();
    match rt.dispatch(&cmd, attrs) {
        Ok(r) => {
            let evt = r.event.as_ref()
                .map(|e| format!(r#","event":"{}""#, e.name))
                .unwrap_or_default();
            ("200 OK", format!(
                r#"{{"ok":true,"aggregate_type":"{}","aggregate_id":"{}"{}}}"#,
                r.aggregate_type, r.aggregate_id, evt
            ))
        }
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
