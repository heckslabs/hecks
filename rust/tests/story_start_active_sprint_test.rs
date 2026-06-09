//! Story.Start active-sprint gate (#3) : a story may only start when its sprint
//! is in the "active" lifecycle state — the twin of the contracts-ratified
//! front-bookend. given { Sprint(sprint).state == "active" } (cross-aggregate
//! POINT gate). Starting a story whose sprint is merely planned (not yet
//! activated) is out-of-scope work ; the gate refuses it.

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
fn field(rt: &Runtime, agg: &str, id: &str, f: &str) -> Option<String> {
    rt.all_qualified(Some("Plan"), agg).into_iter().find(|r| r.id == id)
        .and_then(|r| r.fields.get(f).map(|v| v.to_string()))
}

fn seed_tasked_story(rt: &mut Runtime, story: &str) {
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s(story)), ("title", s(story)), ("tier", s("1")),
        ("summary", s("x")), ("target", s("y")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[("story", s(story)), ("sprint_ref", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("story", s(story))])).unwrap();
}

#[test]
fn start_refused_when_sprint_planned_allowed_when_active() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![]);

    // Sprint 1 : planned + ratified, but NOT activated.
    rt.dispatch("Plan::Sprint.Plan", attrs(&[
        ("number", s("1")), ("goal", s("g")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.RatifyContracts", attrs(&[("sprint", s("1")), ("contracts", s("c"))])).unwrap();

    seed_tasked_story(&mut rt, "sp1");
    // Sprint is planned (not active) — Start must be refused.
    let refused = rt.dispatch("Plan::Story.Start", attrs(&[("story", s("sp1"))]));
    assert!(refused.is_err(),
        "Start must be refused while the sprint is planned, got: {:?}", refused);
    assert_eq!(field(&rt, "Story", "sp1", "state").as_deref(), Some("tasked"),
        "a refused Start must leave the story tasked");

    // Activate the sprint — now Start succeeds.
    rt.dispatch("Plan::Sprint.Activate", attrs(&[("sprint", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.Start", attrs(&[("story", s("sp1"))])).unwrap();
    assert_eq!(field(&rt, "Story", "sp1", "state").as_deref(), Some("started"),
        "once the sprint is active the same story starts");
}
