//! Authz gate FQN-resolution — the forbid-bypass regression invariant.
//!
//! SECURITY-gate-matches-raw-not-fqn (2026-07-03) : the PDP gate used to match a
//! policy `action` pattern against the RAW command string the caller typed, and
//! resolve the bare name to its canonical `Domain::Aggregate.Command` FQN only
//! LATER, in the dispatch path. So a namespace-scoped `forbid Pizzas::Order.*`
//! was ESCAPED by dispatching the bare verb `PlaceOrder` (which never
//! prefix-matched the pattern), and a namespace `permit Pizzas::*` wrongly failed
//! a bare-verb caller. The fix resolves the action to the SAME canonical target
//! the dispatch path would execute BEFORE the policy match.
//!
//! The invariant proven here : a BARE dispatch and a fully-qualified dispatch of
//! the SAME command produce the IDENTICAL gate verdict — for a namespace forbid
//! (both DENY, the security repro), a namespace permit (both ADMIT), and on the
//! query read path (both ADMIT). Socket-free : drives the Runtime directly, like
//! authorize_pdp_test / authz_roster_test.
//!
//! [antibody-exempt: rust/tests/authz_fqn_resolution_test.rs — kernel-floor authz
//!  gate test, security fix, authorized by Chris 2026-07-03]

use std::collections::HashMap;
use storehouse::parser;
use storehouse::runtime::{Runtime, RuntimeError, Value};

const GATING: &str =
    include_str!("../../hecks_conception/aggregates/storehouse/bluebook/storehouse.bluebook");
const AUTHZ: &str =
    include_str!("../../hecks_conception/aggregates/framework/authorization/authorization.bluebook");
const PIZZAS: &str = include_str!("fixtures/pizzas_authz.bluebook");

fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), Value::Str(v.to_string()))).collect()
}

/// A command dispatch stamped with an agent principal (never System, so the PDP
/// — not origin-admit — decides).
fn as_agent(auth: &str, extra: &[(&str, &str)]) -> HashMap<String, Value> {
    let mut m = a(extra);
    m.insert("actor_kind".to_string(), Value::Str("agent".to_string()));
    m.insert("actor_auth_id".to_string(), Value::Str(auth.to_string()));
    m
}

fn as_agent_str(auth: &str) -> HashMap<String, String> {
    let mut m: HashMap<String, String> = HashMap::new();
    m.insert("actor_kind".to_string(), "agent".to_string());
    m.insert("actor_auth_id".to_string(), auth.to_string());
    m
}

fn scrub_env() {
    std::env::remove_var("HECKS_GOVERNANCE_OFF");
    std::env::remove_var("HECKS_SESSION_AUTH_ID");
    std::env::remove_var("HECKS_PRINCIPAL_KIND");
}

fn booted() -> Runtime {
    scrub_env();
    let mut domain = parser::parse(GATING);
    domain.aggregates.extend(parser::parse(AUTHZ).aggregates);
    domain.aggregates.extend(parser::parse(PIZZAS).aggregates);
    Runtime::boot_with_hecksagons(domain, None, vec![])
}

/// Turn deny-by-default on (declare the standing PDP gate as System).
fn turn_on_pdp(rt: &mut Runtime) {
    rt.dispatch(
        "Declare",
        a(&[("name", "authorize"), ("phase", "before"), ("check", "authorize"), ("pattern", "*"), ("order", "30")]),
    )
    .expect("Declare authorize gate");
}

fn assign(rt: &mut Runtime, auth: &str, role: &str) {
    rt.dispatch(
        "Authorization::RoleAssignment.Assign",
        a(&[("auth_identity_id", auth), ("role_name", role)]),
    )
    .expect("Assign role");
}

fn permit(rt: &mut Runtime, id: &str, principal: &str, action: &str) {
    rt.dispatch(
        "Authorization::Policy.Permit",
        a(&[("id", id), ("principal", principal), ("action", action), ("resource", "*"), ("condition", "-"), ("expires_at", "-")]),
    )
    .expect("Permit");
}

fn forbid(rt: &mut Runtime, id: &str, principal: &str, action: &str) {
    rt.dispatch(
        "Authorization::Policy.Forbid",
        a(&[("id", id), ("principal", principal), ("action", action), ("resource", "*"), ("condition", "-"), ("expires_at", "-")]),
    )
    .expect("Forbid");
}

fn assert_forbidden(r: Result<(), RuntimeError>, ctx: &str) {
    match r {
        Ok(()) => panic!("{}: expected a FORBID deny, got ok (the bypass)", ctx),
        Err(RuntimeError::Unauthorized { required, .. }) => assert!(
            required.contains("forbidden"),
            "{}: expected a forbid-override deny, got: {}",
            ctx, required
        ),
        Err(e) => panic!("{}: expected Unauthorized(forbidden), got {:?}", ctx, e),
    }
}

// ── (1) namespace FORBID + broad permit : bare AND FQN both DENY (the repro) ──

/// carol : role `broad`, `permit(*)` + `forbid(Pizzas::Order.*)`. The forbid
/// carve-out must hold whether PlaceOrder is dispatched BARE or fully-qualified.
/// Before the fix, bare `PlaceOrder` returned ok:true — the bypass.
#[test]
fn namespace_forbid_denies_bare_and_fqn() {
    let mut rt = booted();
    turn_on_pdp(&mut rt);
    assign(&mut rt, "carol", "broad");
    permit(&mut rt, "carol-all", "broad", "*");
    forbid(&mut rt, "carol-no-order", "broad", "Pizzas::Order.*");

    // FQN form — matched the forbid even before the fix.
    assert_forbidden(
        rt.dispatch("Pizzas::Order.PlaceOrder", as_agent("carol", &[("ref", "o-fqn")])).map(|_| ()),
        "FQN PlaceOrder under forbid Pizzas::Order.*",
    );
    // BARE form — the bypass. Must now ALSO deny (identical verdict).
    assert_forbidden(
        rt.dispatch("PlaceOrder", as_agent("carol", &[("ref", "o-bare")])).map(|_| ()),
        "BARE PlaceOrder under forbid Pizzas::Order.* (was the bypass)",
    );
}

// ── (2) namespace PERMIT : bare AND FQN both ADMIT ──

/// alice : role `customer`, `permit(Pizzas::*)`. A namespace permit must admit
/// the permitted command in BOTH dispatch shapes. Before the fix the bare form
/// fell to deny-by-default (the pattern couldn't prefix-match a bare verb).
#[test]
fn namespace_permit_admits_bare_and_fqn() {
    let mut rt = booted();
    turn_on_pdp(&mut rt);
    assign(&mut rt, "alice", "customer");
    permit(&mut rt, "alice-pizzas", "customer", "Pizzas::*");

    rt.dispatch("Pizzas::Pizza.CreatePizza", as_agent("alice", &[("name", "margherita")]))
        .expect("FQN CreatePizza under permit Pizzas::* must admit");
    rt.dispatch("CreatePizza", as_agent("alice", &[("name", "marinara")]))
        .expect("BARE CreatePizza under permit Pizzas::* must admit (was deny-by-default)");
}

// ── (3) query read path : a namespace permit admits bare AND qualified query ──

/// The read gate keys on the same raw string, so the same bypass/lockout applied
/// to queries. A namespace `permit(Pizzas::*)` must admit the `Menu` read whether
/// it enters BARE (`Menu`) or qualified (`Pizzas::Pizza.menu`).
#[test]
fn namespace_permit_admits_bare_and_qualified_query() {
    let mut rt = booted();
    turn_on_pdp(&mut rt);
    assign(&mut rt, "alice", "customer");
    permit(&mut rt, "alice-pizzas", "customer", "Pizzas::*");

    rt.query("Pizzas::Pizza.menu", as_agent_str("alice"))
        .expect("qualified Menu read under permit Pizzas::* must admit");
    rt.query("Menu", as_agent_str("alice"))
        .expect("BARE Menu read under permit Pizzas::* must admit (was deny-by-default)");
}

// ── guardrails : the fix must not weaken deny-by-default or origin-admit ──

/// A command with NO covering permit still denies by default — the fix widens
/// what a permit/forbid MATCHES, never what it admits absent a permit.
#[test]
fn deny_by_default_survives_for_unpermitted_agent() {
    let mut rt = booted();
    turn_on_pdp(&mut rt);
    assign(&mut rt, "dave", "customer"); // no permit for `customer`
    match rt.dispatch("CreatePizza", as_agent("dave", &[("name", "plain")])).unwrap_err() {
        RuntimeError::Unauthorized { required, .. } => {
            assert!(required.contains("permit"), "expected deny-by-default, got: {}", required)
        }
        e => panic!("expected Unauthorized(deny-by-default), got {:?}", e),
    }
}

/// System origin (no actor stamp) is still admitted by origin, both dispatch
/// shapes, even with a namespace forbid standing — the operator is never locked
/// out and the fix leaves the first arm untouched.
#[test]
fn system_origin_admitted_bare_and_fqn_despite_forbid() {
    let mut rt = booted();
    turn_on_pdp(&mut rt);
    forbid(&mut rt, "no-order", "*", "Pizzas::Order.*");
    rt.dispatch("Pizzas::Order.PlaceOrder", a(&[("ref", "sys-fqn")]))
        .expect("System admitted by origin (FQN) despite forbid");
    rt.dispatch("PlaceOrder", a(&[("ref", "sys-bare")]))
        .expect("System admitted by origin (bare) despite forbid");
}
