//! The authenticate before-gate (in-process, one Runtime, memory). Proves the
//! authn half of the door : a Gate with check "authenticate" admits a dispatch
//! iff its principal is a known, ACTIVE AuthIdentity. The gate is
//! DECLARATION-GATED (not self-seeded), so authn is off until turned on by
//! declaring it ; once on :
//!
//!   * a SYSTEM origin is admitted by origin (daemons, cascades, boot) ;
//!   * an AGENT whose auth id is NOT an active AuthIdentity FAILS CLOSED ;
//!   * an AGENT whose auth id IS an active AuthIdentity passes authenticate
//!     (order 10) and then meets the standing rbac gate (order 20) — proving
//!     authenticate admitted it and the two gates compose in order.

use storehouse::parser;
use storehouse::runtime::{Runtime, RuntimeError, Value};
use std::collections::HashMap;

fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter()
        .map(|(k, v)| (k.to_string(), Value::Str(v.to_string())))
        .collect()
}

/// Stamp an agent caller (the reserved principal attrs an external door sets).
fn as_agent(auth: &str, extra: &[(&str, &str)]) -> HashMap<String, Value> {
    let mut m = a(extra);
    m.insert("actor_kind".to_string(), Value::Str("agent".to_string()));
    m.insert("actor_auth_id".to_string(), Value::Str(auth.to_string()));
    m
}

const GATING: &str =
    include_str!("../../hecks_conception/aggregates/language/grammar/gating.bluebook");
const AUTH: &str =
    include_str!("../../hecks_conception/aggregates/framework/agent/auth_identity.bluebook");

fn booted() -> Runtime {
    let mut domain = parser::parse(GATING);
    domain.aggregates.extend(parser::parse(AUTH).aggregates);
    Runtime::boot_with_hecksagons(domain, None, vec![])
}

/// Turn authn ON as a SYSTEM principal (admitted by origin) : establish + verify
/// an identity, then declare the authenticate before-gate (order 10).
fn turn_on_authn(rt: &mut Runtime, ok_id: &str) {
    rt.dispatch("Establish", a(&[("id", ok_id), ("label", "ok"), ("credential", "TOK")]))
        .expect("Establish");
    rt.dispatch("MarkVerified", a(&[("id", ok_id), ("verification_ref", "v1")]))
        .expect("MarkVerified");
    rt.dispatch(
        "Declare",
        a(&[
            ("name", "authenticate"),
            ("phase", "before"),
            ("check", "authenticate"),
            ("pattern", "*"),
            ("order", "10"),
        ]),
    )
    .expect("Declare authenticate gate");
}

#[test]
fn system_origin_is_admitted_even_with_authn_on() {
    let mut rt = booted();
    turn_on_authn(&mut rt, "sess-ok");
    // A System dispatch (no actor_kind) is admitted by origin even with the
    // authenticate gate live — establishing a second identity still works.
    rt.dispatch("Establish", a(&[("id", "sess-2"), ("label", "l"), ("credential", "T")]))
        .expect("system admitted by origin");
}

#[test]
fn unknown_agent_is_denied_by_authenticate() {
    let mut rt = booted();
    turn_on_authn(&mut rt, "sess-ok");
    let err = rt
        .dispatch(
            "Establish",
            as_agent("ghost", &[("id", "x"), ("label", "l"), ("credential", "T")]),
        )
        .unwrap_err();
    match err {
        RuntimeError::Unauthorized { required, .. } => {
            assert!(required.contains("AuthIdentity"), "expected authenticate denial, got: {}", required)
        }
        e => panic!("expected Unauthorized, got {:?}", e),
    }
}

#[test]
fn known_identity_passes_authenticate_then_meets_rbac() {
    let mut rt = booted();
    turn_on_authn(&mut rt, "sess-ok");
    // sess-ok is an active identity -> authenticate (order 10) admits it ; the
    // next gate is the standing rbac-authorize (order 20), which denies because
    // no Agent/role is bound. The denial is the RBAC one, NOT the authenticate
    // one — proving authenticate admitted the known identity and the gates
    // compose in order.
    let err = rt
        .dispatch(
            "Establish",
            as_agent("sess-ok", &[("id", "x"), ("label", "l"), ("credential", "T")]),
        )
        .unwrap_err();
    match err {
        RuntimeError::Unauthorized { required, .. } => assert!(
            !required.contains("AuthIdentity"),
            "authenticate should have passed; got authenticate denial: {}",
            required
        ),
        e => panic!("expected Unauthorized, got {:?}", e),
    }
}
