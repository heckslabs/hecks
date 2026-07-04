//! In-process proof of the embed one-shot entry — the magnus binding calls
//! exactly this. Two halves:
//!
//!  1. `embed::authorized_dispatch` / `embed::gated_query` — the SHARED gate core
//!     that `dispatch_once` / `query_once` boot into — are gate-honest against a
//!     seeded governed authz context: System admits, an unknown agent (ghost)
//!     denies with the governance shape, a permitted agent admits AND the command
//!     applies, and a BARE dispatch and a FULLY-QUALIFIED dispatch of the same
//!     command yield the IDENTICAL verdict (the PR #750 FQN-resolution invariant
//!     flowing through embed). Seeded in-memory (memory adapters), exactly like
//!     authorize_pdp_test / authz_fqn_resolution_test.
//!
//!  2. `embed::dispatch_once` / `embed::query_once` — the FFI wrappers — boot a
//!     real on-disk root in-process and return the verdict JSON, and a bad root
//!     returns `{ ok: false }` WITHOUT unwinding across the boundary (so a future
//!     FFI binding can't segfault its host).
//!
//! [antibody-exempt: rust/tests/embed_dispatch_test.rs — kernel-floor embed entry
//!  proof, authorized by Chris 2026-07-03]

use std::collections::HashMap;

use storehouse::embed::{self, Principal};
use storehouse::parser;
use storehouse::runtime::{Runtime, Value};

const GATING: &str =
    include_str!("../../hecks_conception/aggregates/storehouse/bluebook/storehouse.bluebook");
const AUTHZ: &str =
    include_str!("../../hecks_conception/aggregates/framework/authorization/authorization.bluebook");
const PIZZAS: &str = include_str!("fixtures/pizzas_authz.bluebook");

/// Value attrs for the direct-runtime seeding dispatches (System origin).
fn a(pairs: &[(&str, &str)]) -> HashMap<String, Value> {
    pairs.iter().map(|(k, v)| (k.to_string(), Value::Str(v.to_string()))).collect()
}

/// String params for the embed entry (its public attr shape).
fn sp(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

fn agent(auth: &str) -> Principal {
    Principal::Agent { auth_identity_id: auth.to_string() }
}

fn scrub_env() {
    std::env::remove_var("HECKS_GOVERNANCE_OFF");
    std::env::remove_var("HECKS_SESSION_AUTH_ID");
    std::env::remove_var("HECKS_PRINCIPAL_KIND");
}

/// Boot a governed in-memory runtime: deny-by-default gate ON, `alice` assigned
/// role `customer`, `customer` permitted `Pizzas::*`. `ghost` has no role.
fn booted_governed() -> Runtime {
    scrub_env();
    let mut domain = parser::parse(GATING);
    domain.aggregates.extend(parser::parse(AUTHZ).aggregates);
    domain.aggregates.extend(parser::parse(PIZZAS).aggregates);
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![]);
    rt.dispatch(
        "Declare",
        a(&[("name", "authorize"), ("phase", "before"), ("check", "authorize"), ("pattern", "*"), ("order", "30")]),
    ).expect("declare authorize gate");
    rt.dispatch(
        "Authorization::RoleAssignment.Assign",
        a(&[("auth_identity_id", "alice"), ("role_name", "customer")]),
    ).expect("assign alice customer");
    rt.dispatch(
        "Authorization::Policy.Permit",
        a(&[("id", "alice-pizzas"), ("principal", "customer"), ("action", "Pizzas::*"), ("resource", "*"), ("condition", "-"), ("expires_at", "-")]),
    ).expect("permit customer Pizzas::*");
    rt
}

#[test]
fn embed_core_is_gate_honest_and_fqn_invariant_holds() {
    let mut rt = booted_governed();

    // (1) System is admitted by origin.
    let sys = embed::authorized_dispatch(
        &mut rt, "Pizzas::Pizza.CreatePizza", sp(&[("name", "sys-pie")]), Principal::System);
    assert_eq!(sys["ok"], true, "System must admit: {}", sys);

    // (2) An unknown agent (ghost, no role) is DENIED with the governance shape.
    let ghost = embed::authorized_dispatch(
        &mut rt, "Pizzas::Pizza.CreatePizza", sp(&[("name", "ghost-pie")]), agent("ghost"));
    assert_eq!(ghost["ok"], false, "ghost must deny: {}", ghost);
    assert!(ghost.get("command").is_some(), "denial carries `command` (403 shape): {}", ghost);
    assert!(
        ghost["error"].as_str().unwrap_or("").contains("denied"),
        "denial is a governance error: {}", ghost);

    // (3) A permitted agent admits AND the command applies (state reflects it).
    let alice = embed::authorized_dispatch(
        &mut rt, "Pizzas::Pizza.CreatePizza", sp(&[("name", "margherita")]), agent("alice"));
    assert_eq!(alice["ok"], true, "permitted alice must admit: {}", alice);
    assert!(
        alice["state"].to_string().contains("margherita"),
        "the command applied — state reflects the new pizza: {}", alice);

    // permitted read through the shared query core also admits.
    let menu = embed::gated_query(&mut rt, "Pizzas::Pizza.menu", sp(&[]), agent("alice"));
    assert_ne!(menu["ok"], false, "permitted alice read must admit: {}", menu);

    // (4) BARE and FQN dispatch of the SAME command yield the IDENTICAL verdict.
    let bare_ok = embed::authorized_dispatch(
        &mut rt, "CreatePizza", sp(&[("name", "bare-pie")]), agent("alice"));
    let fqn_ok = embed::authorized_dispatch(
        &mut rt, "Pizzas::Pizza.CreatePizza", sp(&[("name", "fqn-pie")]), agent("alice"));
    assert_eq!(bare_ok["ok"], fqn_ok["ok"], "permitted: bare vs FQN same verdict\nbare={}\nfqn={}", bare_ok, fqn_ok);
    assert_eq!(bare_ok["ok"], true, "permitted bare must admit: {}", bare_ok);

    let bare_deny = embed::authorized_dispatch(
        &mut rt, "CreatePizza", sp(&[("name", "g1")]), agent("ghost"));
    let fqn_deny = embed::authorized_dispatch(
        &mut rt, "Pizzas::Pizza.CreatePizza", sp(&[("name", "g2")]), agent("ghost"));
    assert_eq!(bare_deny["ok"], fqn_deny["ok"], "ghost: bare vs FQN same verdict\nbare={}\nfqn={}", bare_deny, fqn_deny);
    assert_eq!(bare_deny["ok"], false, "unpermitted bare must deny: {}", bare_deny);
}

#[test]
fn dispatch_once_and_query_once_boot_in_process_and_are_panic_safe() {
    scrub_env();
    // A real on-disk root (ungoverned — no Declare, so the gate is off and System
    // admits). Aggregates default to memory, so nothing persists off-box.
    let dir = std::env::temp_dir().join(format!("embed_ffi_{}", std::process::id()));
    let agg = dir.join("aggregates");
    std::fs::create_dir_all(&agg).expect("mkdir temp root");
    std::fs::write(agg.join("pizzas.bluebook"), PIZZAS).expect("write fixture");
    // Pin the corpus/hecksagon walk to the temp tree so no real repo hecksagons load.
    std::env::set_var("HECKS_CONCEPTION_DIR", &dir);
    let root = agg.to_str().unwrap();

    let v = embed::dispatch_once(root, "Pizzas::Pizza.CreatePizza", sp(&[("name", "ffi-pie")]), Principal::System);
    assert_eq!(v["ok"], true, "dispatch_once boots + admits System: {}", v);
    assert_eq!(v["aggregate_type"], "Pizza", "verdict names the aggregate: {}", v);
    assert!(v["state"].to_string().contains("ffi-pie"), "dispatch_once applied the command: {}", v);

    let q = embed::query_once(root, "Pizzas::Pizza.menu", sp(&[]), Principal::System);
    assert!(
        q.get("query").is_some() || q.get("aggregate").is_some(),
        "query_once returns the query-result shape: {}", q);

    // Panic-safety: a nonexistent root returns ok:false, never unwinds.
    let bad = embed::dispatch_once("/nonexistent/embed/root", "No::Thing.Do", sp(&[]), Principal::System);
    assert_eq!(bad["ok"], false, "a bad root returns ok:false (no panic across the boundary): {}", bad);

    std::env::remove_var("HECKS_CONCEPTION_DIR");
    let _ = std::fs::remove_dir_all(&dir);
}
