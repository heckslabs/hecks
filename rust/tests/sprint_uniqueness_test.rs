//! Sprint one-active-per-project uniqueness (#5).
//!
//! Sprint.Activate carries given { Sprint(project).active_peers.empty? } — a
//! cross-aggregate UNIQUENESS gate (the reserved `active_peers` projection :
//! scan Sprints for another already-active sprint sharing this sprint's
//! project). Two sprints in the same project may not both be active ; sprints
//! in DIFFERENT projects can. The self excludes itself naturally (its given
//! runs while it is still planned).

use storehouse::corpus_loader::load_combined_domain;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(p: &[(&str, Value)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}
fn aggregates_dir() -> String {
    format!("{}/../hecks_conception/aggregates", env!("CARGO_MANIFEST_DIR"))
}
fn field(rt: &Runtime, id: &str, f: &str) -> Option<String> {
    rt.all_qualified(Some("Plan"), "Sprint").into_iter().find(|r| r.id == id)
        .and_then(|r| r.fields.get(f).map(|v| v.to_string()))
}
fn plan_sprint(rt: &mut Runtime, number: &str, project: &str) {
    rt.dispatch("Plan::Sprint.Plan", attrs(&[
        ("number", s(number)), ("goal", s("g")), ("project", s(project))])).unwrap();
}

#[test]
fn only_one_sprint_per_project_may_be_active() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![]);

    plan_sprint(&mut rt, "1", "alpha");
    plan_sprint(&mut rt, "2", "alpha");
    plan_sprint(&mut rt, "3", "beta");

    // First alpha activation succeeds (no active peer).
    rt.dispatch("Plan::Sprint.Activate", attrs(&[("id", s("1"))])).unwrap();
    assert_eq!(field(&rt, "1", "state").as_deref(), Some("active"));

    // Second alpha activation REFUSED — sprint 1 is already active in alpha.
    let refused = rt.dispatch("Plan::Sprint.Activate", attrs(&[("id", s("2"))]));
    assert!(refused.is_err(),
        "a second active sprint in the same project must be refused, got: {:?}", refused);
    assert_eq!(field(&rt, "2", "state").as_deref(), Some("planned"),
        "the refused sprint stays planned");

    // A sprint in a DIFFERENT project activates fine (uniqueness is per-project).
    rt.dispatch("Plan::Sprint.Activate", attrs(&[("id", s("3"))])).unwrap();
    assert_eq!(field(&rt, "3", "state").as_deref(), Some("active"),
        "a sprint in a different project is unaffected by alpha's active sprint");
}
