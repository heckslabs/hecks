//! Storehouse-service gate (in-process, one Runtime, memory). Proves "a gate is
//! a storehouse service, not a DSL" : a Gate whose `check` names an ordinary
//! bluebook QUERY (here SessionAllowlist.Permits) is run read-only through the
//! door, and ADMITS iff the query returns a row. No grammar, no Rust verdict —
//! any bluebook query is a gate, declared via Gate.Declare. The principal is a
//! SESSION IDENTITY (not a role — roles are the separate RBAC axis).
//!
//!   * a SYSTEM origin is admitted by origin ;
//!   * an AGENT whose session is NOT admitted is DENIED by the service gate ;
//!   * an AGENT whose session IS admitted passes the service gate (order 5)
//!     and then meets the standing authorize gate (order 20) — proving admission
//!     and that the gates compose in order.

use storehouse::parser;
use storehouse::runtime::{Runtime, RuntimeError, Value};
use std::collections::HashMap;

fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter()
        .map(|(k, v)| (k.to_string(), Value::Str(v.to_string())))
        .collect()
}

/// Stamp an agent caller by its SESSION IDENTITY (the reserved principal attrs
/// an external door sets).
fn as_session(session: &str, extra: &[(&str, &str)]) -> HashMap<String, Value> {
    let mut m = a(extra);
    m.insert("actor_kind".to_string(), Value::Str("agent".to_string()));
    m.insert("actor_auth_id".to_string(), Value::Str(session.to_string()));
    m
}

const GATING: &str =
    include_str!("../../hecks_conception/aggregates/storehouse/bluebook/storehouse.bluebook");
const DEMO: &str = include_str!("fixtures/service_gate_demo.bluebook");

fn booted() -> Runtime {
    let mut domain = parser::parse(GATING);
    domain.aggregates.extend(parser::parse(DEMO).aggregates);
    Runtime::boot_with_hecksagons(domain, None, vec![])
}

/// As System (admitted by origin) : admit a session, then declare a
/// storehouse-service gate whose check is the SessionAllowlist.Permits query.
fn setup(rt: &mut Runtime, admitted_session: &str) {
    rt.dispatch("Admit", a(&[("session", admitted_session)]))
        .expect("Admit");
    rt.dispatch(
        "Declare",
        a(&[
            ("name", "session-allowlist"),
            ("phase", "before"),
            ("check", "SessionAllowlist.Permits"),
            ("pattern", "*"),
            ("order", "5"),
        ]),
    )
    .expect("Declare service gate");
}

#[test]
fn system_origin_is_admitted_by_the_service_gate() {
    let mut rt = booted();
    setup(&mut rt, "chris-laptop");
    // System (no actor_kind) is admitted by origin even with the service gate
    // live — admitting another session still works.
    rt.dispatch("Admit", a(&[("session", "miette-daemon")]))
        .expect("system admitted by origin");
}

#[test]
fn unadmitted_session_is_denied_by_the_service_gate() {
    let mut rt = booted();
    setup(&mut rt, "chris-laptop");
    let err = rt
        .dispatch("Admit", as_session("intruder", &[("session", "x")]))
        .unwrap_err();
    match err {
        RuntimeError::Unauthorized { required, .. } => {
            assert!(required.contains("Permits"), "expected service-gate denial, got: {}", required)
        }
        e => panic!("expected Unauthorized, got {:?}", e),
    }
}

#[test]
fn admitted_session_passes_the_service_gate_then_meets_authorize() {
    let mut rt = booted();
    setup(&mut rt, "chris-laptop");
    // chris-laptop IS admitted -> the service gate (order 5) lets it through ;
    // the next gate is the standing authorize (order 20), which denies
    // because no role is bound. The denial is the authorize (PDP) one, NOT the
    // service-gate one — proving the query admitted the session and the gates
    // compose in order.
    let err = rt
        .dispatch("Admit", as_session("chris-laptop", &[("session", "x")]))
        .unwrap_err();
    match err {
        RuntimeError::Unauthorized { required, .. } => assert!(
            !required.contains("Permits"),
            "service gate should have passed; got service-gate denial: {}",
            required
        ),
        e => panic!("expected Unauthorized, got {:?}", e),
    }
}
