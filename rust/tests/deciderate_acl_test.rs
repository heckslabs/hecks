//! RBAC authorization gate (Layer-2), in-process (one Runtime, memory). Proves
//! the principal-aware gate: the caller is a PRINCIPAL (not always an agent),
//! the command's INLINE `role` is the required-role source of truth, and an
//! agent's role is resolved through the boot-hydrated read-model with parent
//! inheritance + retirement.
//!
//!   * a SYSTEM principal (default — no actor_kind) is admitted by origin ;
//!   * an AGENT whose role matches the command's required role is allowed ;
//!   * an AGENT whose role does NOT match (nor inherit it) is denied ;
//!   * a child role inherits its parent (Captain(parent Player) may Cast) ;
//!   * an agent-claimed call with no resolvable agent FAILS CLOSED ;
//!   * a retired role grants nothing (fail closed) ;
//!   * a System-role command is denied to a non-System agent, allowed to a
//!     system principal ;
//!   * the reserved principal attrs never land on aggregate state.

use storehouse::parser;
use storehouse::runtime::{Runtime, RuntimeError, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value {
    Value::Str(v.to_string())
}
fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), s(v))).collect()
}

const GAME: &str = include_str!("fixtures/deciderate_acl.bluebook");
const ROLE: &str = include_str!("../../hecks_conception/aggregates/framework/agent/role.bluebook");
const AGENT: &str = include_str!("../../hecks_conception/aggregates/framework/agent/agent.bluebook");

/// Boot the game fixture merged with the REAL Role + Agent framework bluebooks,
/// so the RBAC read-model hydrates from genuine Role/Agent state.
fn booted() -> Runtime {
    let mut domain = parser::parse(GAME);
    domain.aggregates.extend(parser::parse(ROLE).aggregates);
    domain.aggregates.extend(parser::parse(AGENT).aggregates);
    Runtime::boot_with_hecksagons(domain, None, vec![])
}

/// Seed a role (name + optional parent) as a SYSTEM principal (no stamp ->
/// default System -> admitted, so seeding is never gated).
fn define_role(rt: &mut Runtime, name: &str, parent: &str) {
    rt.dispatch("Define", a(&[("name", name), ("description", "r"), ("parent_name", parent)]))
        .expect("Role.Define");
}

/// Seed an agent bound to a role and linked to an auth identity, as System.
fn seed_agent(rt: &mut Runtime, name: &str, role: &str, auth: &str) {
    rt.dispatch("Birth", a(&[("name", name), ("description", "a"), ("kind", "human")]))
        .expect("Agent.Birth");
    rt.dispatch("Bind", a(&[("id", name), ("role_name", role)])).expect("Agent.Bind");
    rt.dispatch("LinkAuthIdentity", a(&[("id", name), ("auth_identity_id", auth)]))
        .expect("Agent.LinkAuthIdentity");
}

/// The reserved principal attrs that stamp an agent caller onto a dispatch.
fn as_agent(auth: &str, extra: &[(&str, &str)]) -> HashMap<String, Value> {
    let mut m = a(extra);
    m.insert("actor_kind".to_string(), s("agent"));
    m.insert("actor_auth_id".to_string(), s(auth));
    m
}

#[test]
fn system_principal_is_admitted_by_origin() {
    let mut rt = booted();
    // No actor_kind -> default System -> the Seeker command runs ungated.
    rt.dispatch("Pose", a(&[("id", "d1"), ("question", "q")])).unwrap();
}

#[test]
fn agent_with_matching_role_allowed_mismatch_denied() {
    let mut rt = booted();
    define_role(&mut rt, "Seeker", "");
    seed_agent(&mut rt, "alice", "Seeker", "auth-alice");
    // Pose requires role Seeker ; alice holds Seeker -> allowed.
    rt.dispatch("Pose", as_agent("auth-alice", &[("id", "d1"), ("question", "q")])).unwrap();
    // Cast requires role Player ; alice holds only Seeker -> denied.
    let err = rt
        .dispatch("Cast", as_agent("auth-alice", &[("id", "v1"), ("bubble", "bA")]))
        .unwrap_err();
    assert!(
        matches!(err, RuntimeError::Unauthorized { ref required, .. } if required == "Player"),
        "a Seeker must not Cast ; got {:?}",
        err
    );
}

#[test]
fn child_role_inherits_parent() {
    let mut rt = booted();
    define_role(&mut rt, "Player", "");
    define_role(&mut rt, "Captain", "Player");
    seed_agent(&mut rt, "bob", "Captain", "auth-bob");
    // Cast requires Player ; bob holds Captain (parent Player) -> allowed.
    rt.dispatch("Cast", as_agent("auth-bob", &[("id", "v1"), ("bubble", "bA")])).unwrap();
}

#[test]
fn agent_with_no_resolvable_role_fails_closed() {
    let mut rt = booted();
    let err = rt
        .dispatch("Pose", as_agent("ghost", &[("id", "d1"), ("question", "q")]))
        .unwrap_err();
    assert!(
        matches!(err, RuntimeError::Unauthorized { ref held, .. } if held.is_empty()),
        "an unresolvable agent must fail closed ; got {:?}",
        err
    );
}

#[test]
fn a_retired_role_grants_nothing() {
    let mut rt = booted();
    define_role(&mut rt, "Seeker", "");
    seed_agent(&mut rt, "alice", "Seeker", "auth-alice");
    // Bare "Retire" resolves to Role.Retire (Role precedes Agent in the merged
    // domain) ; retire Seeker, then alice can no longer Pose.
    rt.dispatch("Retire", a(&[("id", "Seeker")])).expect("Role.Retire");
    let err = rt
        .dispatch("Pose", as_agent("auth-alice", &[("id", "d1"), ("question", "q")]))
        .unwrap_err();
    assert!(
        matches!(err, RuntimeError::Unauthorized { .. }),
        "a retired role must grant nothing ; got {:?}",
        err
    );
}

#[test]
fn system_role_command_denied_to_agent_allowed_to_system() {
    let mut rt = booted();
    define_role(&mut rt, "Seeker", "");
    seed_agent(&mut rt, "alice", "Seeker", "auth-alice");
    rt.dispatch("Launch", a(&[("id", "bA"), ("size", "5")])).unwrap();
    // Decay is role System : a non-System agent is denied.
    let err = rt
        .dispatch("Decay", as_agent("auth-alice", &[("bubble", "bA"), ("id", "bA")]))
        .unwrap_err();
    assert!(
        matches!(err, RuntimeError::Unauthorized { ref required, .. } if required == "System"),
        "a System command must be denied to a non-System agent ; got {:?}",
        err
    );
    // A system principal (default) is admitted by origin.
    rt.dispatch("Decay", a(&[("bubble", "bA"), ("id", "bA")])).unwrap();
}

#[test]
fn reserved_principal_attrs_never_land_on_state() {
    let mut rt = booted();
    define_role(&mut rt, "Seeker", "");
    seed_agent(&mut rt, "alice", "Seeker", "auth-alice");
    rt.dispatch("Pose", as_agent("auth-alice", &[("id", "d1"), ("question", "q")])).unwrap();
    let st = rt.find("Decision", "d1").expect("decision exists");
    assert!(!st.fields.contains_key("actor_kind"), "actor_kind must be stripped");
    assert!(!st.fields.contains_key("actor_auth_id"), "actor_auth_id must be stripped");
}
