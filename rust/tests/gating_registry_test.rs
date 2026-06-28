//! Gate registry -> MiddlewareStack hydration (in-process, one Runtime, memory).
//! Proves the door is driven by the Gate grammar : the runtime hydrates its
//! synchronous middleware stack from declared Gating::Gate records (the way the
//! Procfile is the projection of declared Drivers), and the standing
//! rbac-authorize gate is always present — self-seeded unless explicitly
//! redeclared, so declaring OTHER gates never drops authz.
//!
//!   * boot with no Gate records -> the stack falls back to the standing
//!     rbac-authorize before-gate ;
//!   * dispatching Gate.Declare hydrates the declared gate INTO the stack
//!     (alongside the standing rbac gate) on the next dispatch ;
//!   * an AFTER gate is excluded from the before-phase the door vetoes on ;
//!   * Gate.Retire drops the declared gate but the standing rbac gate remains.

use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter()
        .map(|(k, v)| (k.to_string(), Value::Str(v.to_string())))
        .collect()
}

const GATING: &str =
    include_str!("../../hecks_conception/aggregates/language/grammar/bluebook/gating.bluebook");

/// Boot a Runtime over the real Gating grammar bluebook, so `all("Gate")`
/// resolves and Gate.Declare / Gate.Retire dispatch.
fn booted() -> Runtime {
    let domain = parser::parse(GATING);
    Runtime::boot_with_hecksagons(domain, None, vec![])
}

fn before_names(rt: &Runtime, command: &str) -> Vec<String> {
    rt.middleware
        .before_matching(command)
        .map(|e| e.name.clone())
        .collect()
}

#[test]
fn boot_self_seeds_the_standing_rbac_gate() {
    let rt = booted();
    // No Gate records declared -> fall back to the standing rbac-authorize gate.
    assert_eq!(rt.middleware.count(), 1);
    assert_eq!(before_names(&rt, "Any.Command"), vec!["rbac-authorize".to_string()]);
}

#[test]
fn declaring_a_gate_hydrates_it_into_the_stack() {
    let mut rt = booted();
    // Declared as a SYSTEM principal (no actor_kind -> admitted by origin), so
    // the declaration itself is ungated.
    rt.dispatch(
        "Declare",
        a(&[
            ("name", "audit-log"),
            ("phase", "after"),
            ("check", "log-dispatch"),
            ("pattern", "*"),
            ("order", "90"),
        ]),
    )
    .expect("Gate.Declare");
    // The stack now holds the declared gate PLUS the standing rbac self-seed.
    assert_eq!(rt.middleware.count(), 2);
    // audit-log is an AFTER gate -> NOT in the before-phase the door vetoes on ;
    // only the standing rbac-authorize before-gate is.
    assert_eq!(before_names(&rt, "X.Y"), vec!["rbac-authorize".to_string()]);
}

#[test]
fn retiring_a_declared_gate_drops_it_but_keeps_rbac() {
    let mut rt = booted();
    rt.dispatch(
        "Declare",
        a(&[
            ("name", "scoped-authz"),
            ("phase", "before"),
            ("check", "rbac-authorize"),
            ("pattern", "Foo.*"),
            ("order", "5"),
        ]),
    )
    .expect("Gate.Declare");
    // scoped-authz (before, Foo.*) + standing rbac-authorize (before, *).
    assert_eq!(rt.middleware.count(), 2);
    assert_eq!(
        before_names(&rt, "Foo.Bar"),
        vec!["scoped-authz".to_string(), "rbac-authorize".to_string()] // order 5 before 20
    );

    rt.dispatch("Retire", a(&[("name", "scoped-authz")])).expect("Gate.Retire");
    // scoped-authz retired -> excluded ; the standing rbac gate remains.
    assert_eq!(rt.middleware.count(), 1);
    assert_eq!(before_names(&rt, "Foo.Bar"), vec!["rbac-authorize".to_string()]);
}
