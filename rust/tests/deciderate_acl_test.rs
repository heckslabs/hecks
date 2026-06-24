//! Deciderate CAPABILITY ACL, in-process (one Runtime, memory). Proves the
//! Inc4b gate Chris specified : TRUST THE EDGE (a reserved `actor_caps` attr
//! asserts the caller's capability set) + CAPABILITY-BASED matching (a command's
//! `role` IS the capability it requires ; an actor holds a SET).
//!
//!   * ungated when `actor_caps` is absent (CLI / tests / internal stay open) ;
//!   * a Player can Cast (role Player) but NOT Pose (role Seeker) ;
//!   * a multi-cap actor {Seeker,Player} can do both ;
//!   * Admin is the wildcard — anything ;
//!   * a System command (role System) is DENIED from a human entry (reachable
//!     only via cascades, which bypass Runtime::dispatch) ;
//!   * `actor_caps` is reserved meta — it never lands on the aggregate state.

use storehouse::parser;
use storehouse::runtime::{Runtime, RuntimeError, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), s(v))).collect()
}

const SRC: &str = include_str!("fixtures/deciderate_acl.bluebook");

fn booted() -> Runtime {
    Runtime::boot_with_hecksagons(parser::parse(SRC), None, vec![])
}

#[test]
fn ungated_when_no_actor_caps_is_supplied() {
    let mut rt = booted();
    // Back-compat : no actor_caps -> the gate is off, the Seeker command runs.
    rt.dispatch("Pose", a(&[("id", "d1"), ("question", "q")])).unwrap();
}

#[test]
fn player_caps_allow_a_player_command_but_deny_a_seeker_command() {
    let mut rt = booted();
    rt.dispatch("Cast", a(&[("id", "v1"), ("bubble", "bA"), ("actor_caps", "Player")])).unwrap();
    let err = rt.dispatch("Pose", a(&[("id", "d1"), ("question", "q"), ("actor_caps", "Player")])).unwrap_err();
    assert!(matches!(err, RuntimeError::Unauthorized { ref required, .. } if required == "Seeker"),
        "a Player must not pose ; got {:?}", err);
}

#[test]
fn a_multi_capability_actor_can_do_both() {
    let mut rt = booted();
    rt.dispatch("Pose", a(&[("id", "d1"), ("question", "q"), ("actor_caps", "Seeker,Player")])).unwrap();
    rt.dispatch("Cast", a(&[("id", "v1"), ("bubble", "bA"), ("actor_caps", "Seeker,Player")])).unwrap();
}

#[test]
fn admin_is_the_wildcard() {
    let mut rt = booted();
    rt.dispatch("Pose", a(&[("id", "d1"), ("question", "q"), ("actor_caps", "Admin")])).unwrap();
    rt.dispatch("Cast", a(&[("id", "v1"), ("bubble", "bA"), ("actor_caps", "Admin")])).unwrap();
}

#[test]
fn a_system_command_is_denied_from_a_human_entry() {
    let mut rt = booted();
    // Launch has no role -> ungated even with caps.
    rt.dispatch("Launch", a(&[("id", "bA"), ("size", "5"), ("actor_caps", "Player")])).unwrap();
    // Decay is role System : a human entry can never invoke it (only cascades).
    let err = rt.dispatch("Decay", a(&[("bubble", "bA"), ("actor_caps", "Player")])).unwrap_err();
    assert!(matches!(err, RuntimeError::Unauthorized { ref required, .. } if required == "System"),
        "a System command must be denied from a human entry ; got {:?}", err);
}

#[test]
fn actor_caps_is_reserved_meta_and_never_lands_on_state() {
    let mut rt = booted();
    rt.dispatch("Pose", a(&[("id", "d1"), ("question", "q"), ("actor_caps", "Seeker")])).unwrap();
    let st = rt.find("Decision", "d1").expect("decision exists");
    assert!(!st.fields.contains_key("actor_caps"), "actor_caps must be stripped, not stored");
}
