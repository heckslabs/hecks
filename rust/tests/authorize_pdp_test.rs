//! Externalized PDP gate (in-process, one Runtime, memory). Proves the decoupled
//! Cedar-shaped Authorization context drives the verdict : domains carry no authz
//! (Vault.Open has no role), the `authorize` gate consults Policy rules evaluated
//! IN-PROCESS — deny-by-default, forbid-overrides-permit, expiry-excluded, System
//! admitted by origin. Policy is authored in ONE place (the Authorization context)
//! with no domain touched — multi-team by construction.

use storehouse::parser;
use storehouse::runtime::{Runtime, RuntimeError, Value};
use std::collections::HashMap;

fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), Value::Str(v.to_string()))).collect()
}
fn as_agent(auth: &str, extra: &[(&str, &str)]) -> HashMap<String, Value> {
    let mut m = a(extra);
    m.insert("actor_kind".to_string(), Value::Str("agent".to_string()));
    m.insert("actor_auth_id".to_string(), Value::Str(auth.to_string()));
    m
}

const GATING: &str =
    include_str!("../../hecks_conception/aggregates/storehouse/bluebook/storehouse.bluebook");
const AUTHZ: &str =
    include_str!("../../hecks_conception/aggregates/framework/authorization/authorization.bluebook");
const DEMO: &str = include_str!("fixtures/authz_demo.bluebook");

fn booted() -> Runtime {
    let mut domain = parser::parse(GATING);
    domain.aggregates.extend(parser::parse(AUTHZ).aggregates);
    domain.aggregates.extend(parser::parse(DEMO).aggregates);
    Runtime::boot_with_hecksagons(domain, None, vec![])
}

/// As System (admitted by origin) : turn the PDP gate on (declare it), so deny-by-
/// default is in force for agent dispatches of Vault.Open.
fn turn_on_pdp(rt: &mut Runtime) {
    rt.dispatch(
        "Declare",
        a(&[("name", "authorize"), ("phase", "before"), ("check", "authorize"), ("pattern", "*"), ("order", "30")]),
    )
    .expect("Declare authorize gate");
}
fn permit(rt: &mut Runtime, id: &str, principal: &str, action: &str, resource: &str, expires_at: &str) {
    rt.dispatch("Permit", a(&[("id", id), ("principal", principal), ("action", action), ("resource", resource), ("condition", "-"), ("expires_at", expires_at)]))
        .expect("Permit");
}
fn open_as(rt: &mut Runtime, who: &str) -> Result<(), RuntimeError> {
    rt.dispatch("Open", as_agent(who, &[("name", "v1")])).map(|_| ())
}

#[test]
fn system_origin_is_admitted_by_the_pdp() {
    let mut rt = booted();
    turn_on_pdp(&mut rt);
    // No actor_kind -> System -> admitted by origin even with deny-by-default on.
    rt.dispatch("Open", a(&[("name", "v0")])).expect("system admitted by origin");
}

#[test]
fn deny_by_default_no_permit() {
    let mut rt = booted();
    turn_on_pdp(&mut rt);
    match open_as(&mut rt, "alice").unwrap_err() {
        RuntimeError::Unauthorized { required, .. } => {
            assert!(required.contains("authorization permit"), "expected deny-by-default, got: {}", required)
        }
        e => panic!("expected Unauthorized, got {:?}", e),
    }
}

#[test]
fn matching_permit_allows() {
    let mut rt = booted();
    turn_on_pdp(&mut rt);
    permit(&mut rt, "alice-open", "alice", "Open", "*", "-");
    open_as(&mut rt, "alice").expect("permit should allow");
}

#[test]
fn forbid_overrides_permit() {
    let mut rt = booted();
    turn_on_pdp(&mut rt);
    permit(&mut rt, "alice-open", "alice", "Open", "*", "-");
    rt.dispatch("Forbid", a(&[("id", "no-open"), ("principal", "alice"), ("action", "Open"), ("resource", "*"), ("condition", "-"), ("expires_at", "-")]))
        .expect("Forbid");
    match open_as(&mut rt, "alice").unwrap_err() {
        RuntimeError::Unauthorized { required, .. } => {
            assert!(required.contains("forbidden"), "expected forbid-override, got: {}", required)
        }
        e => panic!("expected Unauthorized, got {:?}", e),
    }
}

#[test]
fn expired_permit_excluded() {
    let mut rt = booted();
    turn_on_pdp(&mut rt);
    permit(&mut rt, "stale", "alice", "Open", "*", "2000-01-01T00:00:00Z");
    match open_as(&mut rt, "alice").unwrap_err() {
        RuntimeError::Unauthorized { required, .. } => {
            assert!(required.contains("authorization permit"), "expired permit should not grant, got: {}", required)
        }
        e => panic!("expected Unauthorized, got {:?}", e),
    }
}

#[test]
fn wildcard_principal_permits_any_agent() {
    let mut rt = booted();
    turn_on_pdp(&mut rt);
    permit(&mut rt, "any-open", "*", "Open", "*", "-");
    open_as(&mut rt, "bob").expect("wildcard principal should allow any agent");
}

// ── Read-path gating : queries are authorized symmetrically with commands ──
fn as_agent_str(auth: &str) -> HashMap<String, String> {
    let mut m: HashMap<String, String> = HashMap::new();
    m.insert("actor_kind".to_string(), "agent".to_string());
    m.insert("actor_auth_id".to_string(), auth.to_string());
    m
}

#[test]
fn query_deny_by_default() {
    let mut rt = booted();
    turn_on_pdp(&mut rt);
    // No permit for the List read -> the gated query entry denies (deny-by-default).
    match rt.query("List", as_agent_str("alice")).unwrap_err() {
        RuntimeError::Unauthorized { required, .. } => {
            assert!(required.contains("authorization permit"), "expected query deny-by-default, got: {}", required)
        }
        e => panic!("expected Unauthorized, got {:?}", e),
    }
}

#[test]
fn query_permit_allows() {
    let mut rt = booted();
    turn_on_pdp(&mut rt);
    permit(&mut rt, "alice-list", "alice", "List", "*", "-");
    rt.query("List", as_agent_str("alice")).expect("permit should allow the read");
}

#[test]
fn query_system_admitted() {
    let mut rt = booted();
    turn_on_pdp(&mut rt);
    // System (no actor_kind) -> admitted by origin even with deny-by-default on.
    rt.query("List", HashMap::new()).expect("system read admitted by origin");
}
