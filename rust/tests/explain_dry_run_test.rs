//! The authz `explain` dry-run (Authorization::Policy.Explain) — the read-only
//! decision preview that shares `authorize_check`'s policy-eval core. Proves the
//! EXTRACTION BOUNDARY : the live gate keeps its System-origin short-circuit (see
//! authorize_pdp_test), but the explain dry path runs the shared core with NO
//! short-circuit, so it shows the TRUE policy verdict for any SUBJECT — including a
//! System subject (deny-by-default, not a blanket admit). Routed through the gated
//! query path : the System caller is admitted to run the read ; the SUBJECT is a
//! param. Verdict + matched rules, no dispatch.

use std::collections::HashMap;
use storehouse::parser;
use storehouse::runtime::{Runtime, Value};

const GATING: &str =
    include_str!("../../hecks_conception/aggregates/storehouse/bluebook/storehouse.bluebook");
const AUTHZ: &str =
    include_str!("../../hecks_conception/aggregates/framework/authorization/authorization.bluebook");

fn booted() -> Runtime {
    let mut d = parser::parse(GATING);
    d.aggregates.extend(parser::parse(AUTHZ).aggregates);
    Runtime::boot_with_hecksagons(d, None, vec![])
}

fn sv(p: &[(&str, &str)]) -> HashMap<String, String> {
    p.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}
fn vv(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter()
        .map(|(k, v)| (k.to_string(), Value::Str(v.to_string())))
        .collect()
}

/// Explain as a SYSTEM caller (no actor_kind -> admitted to run the read). The
/// `principal` attr is the SUBJECT being explained, the `action` the dispatch.
fn explain(rt: &mut Runtime, subject: &str, action: &str) -> serde_json::Value {
    rt.query(
        "Authorization::Policy.Explain",
        sv(&[("principal", subject), ("action", action)]),
    )
    .expect("explain is admitted for a System caller")
}
fn permit(rt: &mut Runtime, id: &str, principal: &str, action: &str) {
    rt.dispatch(
        "Permit",
        vv(&[
            ("id", id),
            ("principal", principal),
            ("action", action),
            ("resource", "*"),
            ("condition", "-"),
            ("expires_at", "-"),
        ]),
    )
    .expect("Permit");
}
fn forbid(rt: &mut Runtime, id: &str, principal: &str, action: &str) {
    rt.dispatch(
        "Forbid",
        vv(&[
            ("id", id),
            ("principal", principal),
            ("action", action),
            ("resource", "*"),
            ("condition", "-"),
            ("expires_at", "-"),
        ]),
    )
    .expect("Forbid");
}

#[test]
fn explain_deny_by_default_with_no_policy() {
    let mut rt = booted();
    let r = explain(&mut rt, "alice", "Open");
    assert_eq!(r["verdict"], "deny-by-default");
    assert_eq!(r["subject"], "alice");
    assert!(r["matched_rules"].as_array().unwrap().is_empty());
}

#[test]
fn explain_shows_a_matching_permit() {
    let mut rt = booted();
    permit(&mut rt, "alice-open", "alice", "Open");
    let r = explain(&mut rt, "alice", "Open");
    assert_eq!(r["verdict"], "permit");
    let matched = r["matched_rules"].as_array().unwrap();
    assert!(matched.iter().any(|m| m.as_str().unwrap().contains("permit:alice-open")));
}

#[test]
fn explain_shows_forbid_override() {
    let mut rt = booted();
    permit(&mut rt, "alice-open", "alice", "Open");
    forbid(&mut rt, "no-open", "alice", "Open");
    let r = explain(&mut rt, "alice", "Open");
    assert_eq!(r["verdict"], "forbid");
    let matched = r["matched_rules"].as_array().unwrap();
    assert!(matched.iter().any(|m| m.as_str().unwrap().contains("forbid:no-open")));
}

#[test]
fn explain_does_not_short_circuit_a_system_subject() {
    // The BOUNDARY : the live gate admits a System-origin CALLER by origin
    // (authorize_pdp_test), but explain must show the SUBJECT's true policy
    // verdict — never a blanket admit — even when the subject is "System".
    let mut rt = booted();
    let r = explain(&mut rt, "System", "Open");
    assert_eq!(
        r["verdict"], "deny-by-default",
        "explain must evaluate policy for the subject, not short-circuit System"
    );
}
