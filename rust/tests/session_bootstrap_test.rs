//! Session bootstrap, end to end : the non-circular establishment + the full
//! authn+authz chain composing. At session start the FLOOR (System origin)
//! establishes the identity and authors a time-bounded PDP permit ; the agent
//! then flows through BOTH gates — authenticate (order 10 : active AuthIdentity)
//! and authorize (order 20 : PDP permit). Proves you never authenticate-to-
//! authenticate (establishment is System), and that the two gates compose.

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

const GATING: &str = include_str!("../../hecks_conception/aggregates/storehouse/bluebook/storehouse.bluebook");
const AUTHZ: &str = include_str!("../../hecks_conception/aggregates/framework/authorization/authorization.bluebook");
const AUTHID: &str = include_str!("../../hecks_conception/aggregates/framework/agent/bluebook/auth_identity.bluebook");
const DEMO: &str = include_str!("fixtures/authz_demo.bluebook");

fn booted() -> Runtime {
    let mut d = parser::parse(GATING);
    d.aggregates.extend(parser::parse(AUTHZ).aggregates);
    d.aggregates.extend(parser::parse(AUTHID).aggregates);
    d.aggregates.extend(parser::parse(DEMO).aggregates);
    Runtime::boot_with_hecksagons(d, None, vec![])
}

/// The FLOOR : as System (admitted by origin), turn on both gates. Establishment
/// of the per-session identity + permit happens per test (System dispatches).
fn turn_on(rt: &mut Runtime) {
    rt.dispatch("Declare", a(&[("name", "authenticate"), ("phase", "before"), ("check", "authenticate"), ("pattern", "*"), ("order", "10")])).expect("authn gate");
    rt.dispatch("Declare", a(&[("name", "authorize"), ("phase", "before"), ("check", "authorize"), ("pattern", "*"), ("order", "20")])).expect("authz gate");
}
/// System-origin session establishment : mint+verify the identity, author its permit.
fn establish_session(rt: &mut Runtime, sub: &str, action: &str) {
    rt.dispatch("Establish", a(&[("id", sub), ("label", "s"), ("credential", "TOK")])).expect("Establish");
    rt.dispatch("MarkVerified", a(&[("id", sub), ("verification_ref", "v")])).expect("MarkVerified");
    rt.dispatch("Permit", a(&[("id", &format!("{}-{}", sub, action)), ("principal", sub), ("action", action), ("resource", "*"), ("condition", "-"), ("expires_at", "-")])).expect("Permit");
}

#[test]
fn established_session_passes_both_gates() {
    let mut rt = booted();
    turn_on(&mut rt);
    establish_session(&mut rt, "alice-sess", "Open");
    // authenticate (active identity) AND authorize (permit) both pass -> Open runs.
    rt.dispatch("Open", as_agent("alice-sess", &[("name", "v1")])).expect("established + permitted session should pass both gates");
}

#[test]
fn unestablished_session_fails_authentication_first() {
    let mut rt = booted();
    turn_on(&mut rt);
    // "ghost" was never established -> the authenticate gate (order 10) denies
    // BEFORE authorize even runs.
    match rt.dispatch("Open", as_agent("ghost", &[("name", "v1")])).unwrap_err() {
        RuntimeError::Unauthorized { required, .. } => assert!(required.contains("AuthIdentity"), "expected authn denial, got: {}", required),
        e => panic!("expected Unauthorized, got {:?}", e),
    }
}

#[test]
fn established_but_unpermitted_session_fails_authorization() {
    let mut rt = booted();
    turn_on(&mut rt);
    // Identity established (passes authenticate) but NO permit authored -> the
    // authorize PDP gate (order 20) denies. Proves the gates compose in order.
    rt.dispatch("Establish", a(&[("id", "bob-sess"), ("label", "s"), ("credential", "TOK")])).expect("Establish");
    rt.dispatch("MarkVerified", a(&[("id", "bob-sess"), ("verification_ref", "v")])).expect("MarkVerified");
    match rt.dispatch("Open", as_agent("bob-sess", &[("name", "v1")])).unwrap_err() {
        RuntimeError::Unauthorized { required, .. } => assert!(required.contains("authorization permit"), "expected authz denial, got: {}", required),
        e => panic!("expected Unauthorized, got {:?}", e),
    }
}
