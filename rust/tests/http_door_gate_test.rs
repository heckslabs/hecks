//! HTTP client-door gate test — the THIRD door gets the recipe.
//!
//! `routes::route` is a pure `(method, path, body, bearer, posture, rt) ->
//! (status, body)` function, so the whole four-case matrix runs socket-free :
//!   (a) no header — Open -> admitted as System ; Governed -> 403
//!   (b) `Bearer ghost` -> 403 (denied, BOTH postures)
//!   (c) a rostered bearer with permits -> admitted
//!   (d) the same bearer on a forbidden namespace -> 403
//! Plus : raw introspection routes answer 403 wholesale under a governed
//! door, a dispatch denial is 403 (not 422), and the door keeps serving
//! after every denial (resident server — never exits).
//!
//! Roster/boot coupling : serve boots via `boot_with_hecksagons`, NOT
//! run_boot — the BootCompleted establishment policies do not fire, so
//! RoleAssignment/Policy records do NOT self-seed. The tests author them
//! directly, exactly as a governed client root seeds them at boot.

use std::cell::RefCell;
use std::collections::HashMap;
use storehouse::parser;
use storehouse::runtime::acl_readmodel::DoorPosture;
use storehouse::runtime::{Runtime, Value};
use storehouse::server::route;

const AUTHZ: &str =
    include_str!("../../hecks_conception/aggregates/framework/authorization/authorization.bluebook");
const DEMO: &str = include_str!("fixtures/authz_demo.bluebook");

fn a(pairs: &[(&str, &str)]) -> HashMap<String, Value> {
    pairs.iter().map(|(k, v)| (k.to_string(), Value::Str(v.to_string()))).collect()
}

/// Env hygiene — never let the ambient deploy-floor escape or a session
/// identity leak into a posture test (cold_read_gate_test precedent :
/// env_remove HECKS_GOVERNANCE_OFF + the two principal vars).
fn scrub_env() {
    std::env::remove_var("HECKS_GOVERNANCE_OFF");
    std::env::remove_var("HECKS_SESSION_AUTH_ID");
    std::env::remove_var("HECKS_PRINCIPAL_KIND");
}

fn booted() -> RefCell<Runtime> {
    scrub_env();
    let mut domain = parser::parse(AUTHZ);
    domain.aggregates.extend(parser::parse(DEMO).aggregates);
    RefCell::new(Runtime::boot_with_hecksagons(domain, None, vec![]))
}

/// Author the roster directly : tok_alice holds role `client`, and `client`
/// is permitted the Vault read surface + the Open command. System-origin
/// dispatches (unstamped) author the Authorization records.
fn roster(rt: &RefCell<Runtime>) {
    let mut rt = rt.borrow_mut();
    rt.dispatch(
        "Authorization::RoleAssignment.Assign",
        a(&[("auth_identity_id", "tok_alice"), ("role_name", "client")]),
    ).expect("Assign role");
    for (id, action) in [
        ("p-list", "AuthzDemo::Vault.list"),
        ("p-state", "Vault.state"),
        ("p-open", "Open"),
    ] {
        rt.dispatch(
            "Authorization::Policy.Permit",
            a(&[("id", id), ("principal", "client"), ("action", action),
                ("resource", "*"), ("condition", "-"), ("expires_at", "-")]),
        ).expect("Permit");
    }
}

// ── (a) no header ──

#[test]
fn open_no_header_admits_as_system() {
    let rt = booted();
    let (status, body) = route("GET", "/query/list", "", None, DoorPosture::Open, &rt);
    assert_eq!(status, "200 OK", "open door + no header must stay System-admitted: {}", body);
    assert!(body.contains("\"query\":\"List\""), "query should resolve: {}", body);
}

#[test]
fn governed_no_header_denies() {
    let rt = booted();
    let (status, body) = route("GET", "/query/list", "", None, DoorPosture::Governed, &rt);
    assert_eq!(status, "403 Forbidden", "governed door + no header must fail closed: {}", body);
    assert!(body.contains("\"ok\":false"), "deny body is JSON: {}", body);
    // The resident door keeps serving after a denial.
    let (status, _) = route("GET", "/health", "", None, DoorPosture::Governed, &rt);
    assert_eq!(status, "200 OK", "server must keep answering after a denial");
}

// ── (b) ghost bearer — denied under BOTH postures ──

#[test]
fn ghost_bearer_denied_both_postures() {
    let rt = booted();
    for posture in [DoorPosture::Open, DoorPosture::Governed] {
        let (status, body) = route("GET", "/query/list", "", Some("ghost"), posture, &rt);
        assert_eq!(status, "403 Forbidden",
            "unrostered bearer must be denied under {:?}: {}", posture, body);
    }
}

// ── (c) rostered bearer with permits ──

#[test]
fn rostered_bearer_admitted_to_query() {
    let rt = booted();
    roster(&rt);
    let (status, body) =
        route("GET", "/query/list", "", Some("tok_alice"), DoorPosture::Governed, &rt);
    assert_eq!(status, "200 OK", "rostered bearer with a permit must be admitted: {}", body);
}

#[test]
fn rostered_bearer_admitted_to_state_read() {
    let rt = booted();
    roster(&rt);
    rt.borrow_mut()
        .dispatch("AuthzDemo::Vault.Open", a(&[("name", "v1")]))
        .expect("seed a vault as System");
    let (status, body) =
        route("GET", "/aggregates/Vault/v1", "", Some("tok_alice"), DoorPosture::Governed, &rt);
    assert_eq!(status, "200 OK", "permitted Vault.state read must be admitted: {}", body);
    assert!(body.contains("\"id\":\"v1\""), "the record projects: {}", body);
}

#[test]
fn rostered_bearer_dispatches_permitted_command() {
    let rt = booted();
    roster(&rt);
    let body = r#"{"command": "Open", "attrs": {"name": "v9"}}"#;
    let (status, resp) =
        route("POST", "/dispatch", body, Some("tok_alice"), DoorPosture::Governed, &rt);
    assert_eq!(status, "200 OK", "permitted command must dispatch: {}", resp);
    assert!(resp.contains("\"ok\":true"), "{}", resp);
}

// ── (d) same bearer, forbidden namespace ──

#[test]
fn rostered_bearer_denied_on_forbidden_namespace() {
    let rt = booted();
    roster(&rt);
    // No permit covers `Secret.state` — deny-by-default 403, and the gate
    // runs BEFORE the find, so the answer never leaks record existence.
    let (status, body) =
        route("GET", "/aggregates/Secret/xyz", "", Some("tok_alice"), DoorPosture::Governed, &rt);
    assert_eq!(status, "403 Forbidden", "unpermitted namespace must deny: {}", body);
}

#[test]
fn dispatch_denial_is_403_not_422() {
    let rt = booted();
    let body = r#"{"command": "Open", "attrs": {"name": "vX"}}"#;
    let (status, resp) =
        route("POST", "/dispatch", body, Some("ghost"), DoorPosture::Governed, &rt);
    assert_eq!(status, "403 Forbidden",
        "an Unauthorized dispatch must map to 403, not the generic 422: {}", resp);
    assert!(resp.contains("\"ok\":false"), "{}", resp);
    // Follow-up System work still flows — the door never exits on deny.
    let (status, _) = route("GET", "/health", "", None, DoorPosture::Governed, &rt);
    assert_eq!(status, "200 OK");
}

// ── raw introspection : 403 wholesale under governed, unchanged under open ──

#[test]
fn introspection_closed_under_governed() {
    let rt = booted();
    for path in ["/domain", "/aggregates", "/events", "/policies"] {
        let (status, body) = route("GET", path, "", None, DoorPosture::Governed, &rt);
        assert_eq!(status, "403 Forbidden", "{} must close under a governed door: {}", path, body);
        // Even a rostered bearer gets 403 — wholesale, not per-phrase.
        let (status, _) = route("GET", path, "", Some("tok_alice"), DoorPosture::Governed, &rt);
        assert_eq!(status, "403 Forbidden", "{} closes for bearers too", path);
    }
}

#[test]
fn introspection_unchanged_under_open() {
    let rt = booted();
    for path in ["/domain", "/aggregates", "/events", "/policies"] {
        let (status, _) = route("GET", path, "", None, DoorPosture::Open, &rt);
        assert_eq!(status, "200 OK", "{} must stay open under an open door", path);
    }
}
