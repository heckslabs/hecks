//! P2b — dependency replication. unresolved_dep_count is the LOCAL twin of the old
//! cross-aggregate dependency gate. AddDependency +1 (fail-closed) ; when a dependency
//! story reaches a terminal state, the resolve_deps adapter fans DecUnresolvedDeps over
//! Story.DependentsOf (the contains-where reverse lookup, aggregate-local). No sibling read.

use storehouse::corpus_loader::load_combined_domain;
use storehouse::hecksagon_parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(p: &[(&str, Value)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}
const RESOLVE_DEPS_HEX: &str = include_str!(
    "../../hecks_conception/aggregates/plan/hecksagons/resolve_deps.hecksagon"
);
fn aggregates_dir() -> String {
    format!("{}/../hecks_conception/aggregates", env!("CARGO_MANIFEST_DIR"))
}
fn count(rt: &Runtime, story: &str) -> Option<String> {
    rt.all_qualified(Some("Plan"), "Story").into_iter().find(|r| r.id == story)
        .and_then(|r| r.fields.get("unresolved_dep_count").map(|v| v.to_string()))
}
fn cap(rt: &mut Runtime, r: &str) {
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s(r)), ("title", s(r)), ("tier", s("1")),
        ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
}

#[test]
fn resolving_a_dependency_decrements_the_dependents_count() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![hecksagon_parser::parse(RESOLVE_DEPS_HEX)]);

    cap(&mut rt, "a");
    cap(&mut rt, "x");
    rt.dispatch("Plan::Story.AddDependency", attrs(&[("id", s("a")), ("dependency", s("x"))])).unwrap();
    assert_eq!(count(&rt, "a").as_deref(), Some("1"), "AddDependency increments unresolved_dep_count");

    // x reaches a terminal state -> resolve_deps fans DecUnresolvedDeps over DependentsOf(x) -> a.
    rt.dispatch("Plan::Story.Cancel", attrs(&[("id", s("x"))])).unwrap();
    assert_eq!(count(&rt, "a").as_deref(), Some("0"),
        "resolving dependency x decremented the count on its dependent a");
}

#[test]
fn an_unrelated_resolution_does_not_decrement() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![hecksagon_parser::parse(RESOLVE_DEPS_HEX)]);
    cap(&mut rt, "a");
    cap(&mut rt, "x");
    cap(&mut rt, "y");
    rt.dispatch("Plan::Story.AddDependency", attrs(&[("id", s("a")), ("dependency", s("x"))])).unwrap();
    // cancel y (NOT a dependency of a) -> a's count unchanged.
    rt.dispatch("Plan::Story.Cancel", attrs(&[("id", s("y"))])).unwrap();
    assert_eq!(count(&rt, "a").as_deref(), Some("1"), "an unrelated resolution must not decrement a");
}
