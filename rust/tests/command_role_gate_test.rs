//! command_role_gate_test.rs — a command's declared `role` ENFORCES.
//!
//! The reported bug : a user switched the UI to "Customer" and ran `CheckOut`
//! (a `role "System"` command) — and it went through. The word `role` in the
//! model meant nothing at runtime. This test pins the reconciliation locked with
//! the owner : the command's declared `role` (the DDD / EventStorming actor) is
//! the ENFORCED DEFAULT — a caller acting AS a different role is refused, UNLESS
//! an explicit Authorization Policy permits ; an explicit `Forbid` still wins.
//! So `role` is BOTH the ubiquitous-language persona AND a deny-by-default gate,
//! and the decoupled Cedar-shaped PDP keeps its override job.
//!
//! Tested against the REAL ToolShed demo (examples/workshop_demo/toolshed.bluebook
//! — the domain the bug was found in), composed with the shipped GATING
//! (storehouse.bluebook) and AUTHZ (authorization.bluebook) contexts, exactly as
//! a served deployment composes them. Assertions isolate the GATE by keying on
//! `RuntimeError::Unauthorized` vs anything-else : a gate-passing command may
//! still fail ToolShed's own payload rules, which is NOT a denial.

use std::collections::HashMap;
use storehouse::parser;
use storehouse::runtime::{CommandResult, Runtime, RuntimeError, Value};

const GATING: &str =
    include_str!("../../hecks_conception/aggregates/storehouse/bluebook/storehouse.bluebook");
const AUTHZ: &str =
    include_str!("../../hecks_conception/aggregates/framework/authorization/authorization.bluebook");
const TOOLSHED: &str = include_str!("../../examples/workshop_demo/toolshed.bluebook");

fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), Value::Str(v.to_string()))).collect()
}
/// A dispatch stamped as an authenticated AGENT (actor_kind=agent + auth id),
/// whose ROLE the gate resolves from the seeded RoleAssignment read-model.
fn as_agent(auth: &str, extra: &[(&str, &str)]) -> HashMap<String, Value> {
    let mut m = a(extra);
    m.insert("actor_kind".to_string(), Value::Str("agent".to_string()));
    m.insert("actor_auth_id".to_string(), Value::Str(auth.to_string()));
    m
}

/// Boot ToolShed + AUTHZ + GATING, turn the authorize gate on, and seed the
/// roster the served demo would : owner-alice -> Owner, member-bob -> Member.
/// The seeds dispatch as System (admitted by origin) ; each RoleAssignment write
/// refreshes the RBAC read-model at the entry door, so `role_for_auth` resolves
/// the roles without a manual rehydrate.
fn booted() -> Runtime {
    let mut domain = parser::parse(GATING);
    domain.aggregates.extend(parser::parse(AUTHZ).aggregates);
    domain.aggregates.extend(parser::parse(TOOLSHED).aggregates);
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![]);
    // Declare the authorize gate explicitly (the self-seed skips when a Gate of
    // this name is declared) so deny-by-default is deterministically in force.
    rt.dispatch(
        "Declare",
        a(&[("name", "authorize"), ("phase", "before"), ("check", "authorize"), ("pattern", "*"), ("order", "30")]),
    )
    .expect("declare authorize gate");
    assign(&mut rt, "owner-alice", "Owner");
    assign(&mut rt, "member-bob", "Member");
    rt
}

fn assign(rt: &mut Runtime, auth: &str, role: &str) {
    rt.dispatch(
        "Authorization::RoleAssignment.Assign",
        a(&[("auth_identity_id", auth), ("role_name", role)]),
    )
    .expect("seed RoleAssignment");
}

fn permit(rt: &mut Runtime, id: &str, principal: &str, action: &str) {
    rt.dispatch(
        "Permit",
        a(&[("id", id), ("principal", principal), ("action", action), ("resource", "*"), ("condition", "-"), ("expires_at", "-")]),
    )
    .expect("Permit");
}
fn forbid(rt: &mut Runtime, id: &str, principal: &str, action: &str) {
    rt.dispatch(
        "Forbid",
        a(&[("id", id), ("principal", principal), ("action", action), ("resource", "*"), ("condition", "-"), ("expires_at", "-")]),
    )
    .expect("Forbid");
}

fn is_unauth<T>(res: &Result<T, RuntimeError>) -> bool {
    matches!(res, Err(RuntimeError::Unauthorized { .. }))
}

// EnrollMember with a fully-valid payload : passes ToolShed's own rules, so any
// Err is the GATE, never a payload complaint.
fn enroll_as(rt: &mut Runtime, who: &str) -> Result<CommandResult, RuntimeError> {
    rt.dispatch(
        "ToolShed::Member.EnrollMember",
        as_agent(who, &[("name", "Jo"), ("email", "jo@example.com")]),
    )
}

// ── The reported bug : a Member cannot run a System command ────────────────
#[test]
fn member_is_denied_a_system_command() {
    let mut rt = booted();
    // CheckOut declares `role "System"`. member-bob is Member -> refused.
    let res = rt.dispatch("ToolShed::Tool.CheckOut", as_agent("member-bob", &[("id", "drill-1")]));
    assert!(is_unauth(&res), "a Member must be refused a role \"System\" command, got {:?}", res);
}

// ── The command's own role is the default permit ───────────────────────────
#[test]
fn member_may_run_a_member_command() {
    let mut rt = booted();
    // BorrowTool declares `role "Member"`. member-bob is Member -> the gate
    // passes (any later Err is ToolShed's payload rules, not a denial).
    let res = rt.dispatch("ToolShed::Loan.BorrowTool", as_agent("member-bob", &[("id", "loan-1")]));
    assert!(!is_unauth(&res), "a Member acting as the command's declared role must pass the gate, got {:?}", res);
}

#[test]
fn owner_may_run_an_owner_command() {
    let mut rt = booted();
    // EnrollMember declares `role "Owner"`. owner-alice is Owner -> fully allowed.
    enroll_as(&mut rt, "owner-alice").expect("Owner must run its own Owner command");
}

#[test]
fn owner_is_denied_a_member_command() {
    let mut rt = booted();
    // owner-alice (Owner) on BorrowTool (role Member) : Owner != Member and no
    // Policy permits -> deny-by-default.
    let res = rt.dispatch("ToolShed::Loan.BorrowTool", as_agent("owner-alice", &[("id", "loan-9")]));
    assert!(is_unauth(&res), "an Owner acting on a Member command must be refused, got {:?}", res);
}

// ── Policy is the OVERRIDE ─────────────────────────────────────────────────
#[test]
fn explicit_permit_allows_a_nondeclared_role() {
    let mut rt = booted();
    // A Policy permits member-bob to EnrollMember (role Owner) — the escape hatch.
    permit(&mut rt, "bob-may-enroll", "member-bob", "EnrollMember");
    enroll_as(&mut rt, "member-bob").expect("an explicit Permit must override the command-role default");
}

#[test]
fn explicit_forbid_denies_the_declared_role() {
    let mut rt = booted();
    // owner-alice is EnrollMember's declared role (Owner), so the command-role
    // permit would admit — but an explicit Forbid wins.
    forbid(&mut rt, "no-owner-enroll", "owner-alice", "EnrollMember");
    let res = enroll_as(&mut rt, "owner-alice");
    assert!(is_unauth(&res), "an explicit Forbid must beat the command-role permit, got {:?}", res);
}

// ── The floor holds ────────────────────────────────────────────────────────
#[test]
fn system_origin_is_still_admitted() {
    let mut rt = booted();
    // No actor_kind -> System -> admitted by origin (the cascade path CheckOut
    // actually runs under). Any Err is payload, never the gate.
    let res = rt.dispatch("ToolShed::Tool.CheckOut", a(&[("id", "drill-1")]));
    assert!(!is_unauth(&res), "System origin must be admitted regardless of command role, got {:?}", res);
}

#[test]
fn unrostered_agent_stays_denied() {
    let mut rt = booted();
    // charlie has no RoleAssignment -> role "" -> the non-empty-role guard keeps
    // the command-role permit from firing on an empty match. Deny-by-default.
    let res = rt.dispatch("ToolShed::Loan.BorrowTool", as_agent("charlie", &[("id", "loan-x")]));
    assert!(is_unauth(&res), "an unrostered agent (empty role) must never match a command role, got {:?}", res);
}

// ── Explain shows the implicit permit ──────────────────────────────────────
#[test]
fn explain_shows_the_command_role_permit() {
    let mut rt = booted();
    // The dry Explain path shares evaluate_policy, so it surfaces the same
    // command-role verdict : member-bob (Member) on BorrowTool (role Member).
    let mut attrs: HashMap<String, String> = HashMap::new();
    attrs.insert("principal".to_string(), "member-bob".to_string());
    attrs.insert("action".to_string(), "BorrowTool".to_string());
    let verdict = rt.query("Authorization::Policy.explain", attrs).expect("explain query");
    let text = verdict.to_string();
    assert!(
        text.contains("command-role"),
        "Explain must surface the command-role implicit permit, got {}",
        text
    );
}
