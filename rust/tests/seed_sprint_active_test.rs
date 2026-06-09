//! P1.2 — SprintActivated seeds the replicated sprint_active flag on member stories.
//!
//! DDD replication (the pending_task_count pattern). The seed_sprint_active driven
//! adapter fans MarkSprintActive out over the aggregate-LOCAL Story.BySprint query
//! when a Sprint emits SprintActivated. No aggregate reads a sibling synchronously.
//! Proven in FREEZE order : the story is committed to the sprint while it is planned,
//! then activation seeds it.

use storehouse::corpus_loader::load_combined_domain;
use storehouse::hecksagon_parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(p: &[(&str, Value)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

const SEED_HECKSAGON: &str = include_str!(
    "../../hecks_conception/aggregates/plan/hecksagons/seed_sprint_active.hecksagon"
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
    let hexes = vec![hecksagon_parser::parse(SEED_HECKSAGON)];
    Runtime::boot_with_hecksagons(domain, None, hexes)
}

#[test]
fn sprint_activation_seeds_sprint_active_on_member_stories() {
    let mut rt = boot();
    rt.dispatch("Plan::Sprint.Plan", attrs(&[
        ("number", s("7")), ("goal", s("g")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s("m1")), ("title", s("m1")), ("tier", s("1")),
        ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[
        ("id", s("m1")), ("sprint_ref", s("7"))])).unwrap();

    // before activation the flag is its default
    assert_eq!(field(&rt, "Story", "m1", "sprint_active").as_deref(), Some("false"),
        "sprint_active starts false");

    rt.dispatch("Plan::Sprint.Activate", attrs(&[("id", s("7"))])).unwrap();

    assert_eq!(field(&rt, "Story", "m1", "sprint_active").as_deref(), Some("true"),
        "SprintActivated fanned MarkSprintActive over BySprint(7) and seeded the member story");
}

#[test]
fn a_story_in_a_different_sprint_is_not_seeded() {
    let mut rt = boot();
    rt.dispatch("Plan::Sprint.Plan", attrs(&[("number", s("8")), ("goal", s("g")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.Plan", attrs(&[("number", s("9")), ("goal", s("g")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.Capture", attrs(&[("ref", s("n1")), ("title", s("n1")), ("tier", s("1")), ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[("id", s("n1")), ("sprint_ref", s("9"))])).unwrap();
    rt.dispatch("Plan::Sprint.Activate", attrs(&[("id", s("8"))])).unwrap();
    assert_eq!(field(&rt, "Story", "n1", "sprint_active").as_deref(), Some("false"),
        "activating sprint 8 must not seed a story committed to sprint 9");
}
