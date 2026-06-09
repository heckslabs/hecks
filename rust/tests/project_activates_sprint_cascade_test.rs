//! P1.1 — Project owns active-sprint uniqueness; the cascade activates the Sprint.
//!
//! DDD re-enforcement of the old synchronous Sprint.Activate
//! { Sprint(project).active_peers.empty? } cross-sibling scan. Now: Project owns
//! active_sprint and enforces uniqueness LOCALLY; Project.ActivateSprint emits
//! SprintActivatedByProject; the ActivateSprintOnProjectActivation driven adapter
//! dispatches Sprint.Activate so the Sprint flips its OWN state. No aggregate reads
//! a sibling synchronously.

use storehouse::corpus_loader::load_combined_domain;
use storehouse::hecksagon_parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(p: &[(&str, Value)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

const ACTIVATE_HECKSAGON: &str = include_str!(
    "../../hecks_conception/aggregates/plan/hecksagons/activate_sprint_on_project.hecksagon"
);

fn aggregates_dir() -> String {
    format!("{}/../hecks_conception/aggregates", env!("CARGO_MANIFEST_DIR"))
}

fn field(rt: &Runtime, agg: &str, id: &str, f: &str) -> Option<String> {
    rt.all_qualified(Some("Plan"), agg)
        .into_iter()
        .find(|r| r.id == id)
        .and_then(|r| r.fields.get(f).map(|v| v.to_string()))
}

fn boot() -> Runtime {
    let domain = load_combined_domain(&aggregates_dir());
    let hexes = vec![hecksagon_parser::parse(ACTIVATE_HECKSAGON)];
    Runtime::boot_with_hecksagons(domain, None, hexes)
}

#[test]
fn project_activate_sprint_cascades_to_sprint_active() {
    let mut rt = boot();
    rt.dispatch("Plan::Project.Register", attrs(&[("name", s("castle"))])).unwrap();
    rt.dispatch("Plan::Sprint.Plan", attrs(&[
        ("number", s("99")), ("goal", s("g")), ("project", s("castle"))])).unwrap();
    rt.dispatch("Plan::Project.ActivateSprint", attrs(&[
        ("project", s("castle")), ("sprint_ref", s("99"))])).unwrap();

    assert_eq!(field(&rt, "Project", "castle", "active_sprint").as_deref(), Some("99"),
        "Project records its active sprint locally");
    assert_eq!(field(&rt, "Sprint", "99", "state").as_deref(), Some("active"),
        "the cascade activated the Sprint via SprintActivatedByProject -> Sprint.Activate");
}

#[test]
fn project_refuses_a_second_different_active_sprint() {
    let mut rt = boot();
    rt.dispatch("Plan::Project.Register", attrs(&[("name", s("keep"))])).unwrap();
    rt.dispatch("Plan::Sprint.Plan", attrs(&[("number", s("1")), ("goal", s("g")), ("project", s("keep"))])).unwrap();
    rt.dispatch("Plan::Sprint.Plan", attrs(&[("number", s("2")), ("goal", s("g")), ("project", s("keep"))])).unwrap();
    rt.dispatch("Plan::Project.ActivateSprint", attrs(&[("project", s("keep")), ("sprint_ref", s("1"))])).unwrap();
    let refused = rt.dispatch("Plan::Project.ActivateSprint", attrs(&[("project", s("keep")), ("sprint_ref", s("2"))]));
    assert!(refused.is_err(), "a second different sprint is refused while one is active");
}
