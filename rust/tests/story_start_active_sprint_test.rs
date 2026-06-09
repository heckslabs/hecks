//! Story.Start active-sprint gate, DDD form : a story may only start when its
//! sprint is active — enforced via the REPLICATED local sprint_active flag, not a
//! cross-aggregate read. The seed_sprint_active driven adapter sets the flag on
//! SprintActivated over the sprint's member stories (Story.BySprint). Planned
//! sprint -> flag false -> Start refused ; activate -> seed fires -> Start succeeds.

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
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![hecksagon_parser::parse(SEED_HECKSAGON)]);

    // Sprint 1 : planned + ratified, member story committed BEFORE activation (freeze order).
    rt.dispatch("Plan::Sprint.Plan", attrs(&[
        ("number", s("1")), ("goal", s("g")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.RatifyContracts", attrs(&[("sprint", s("1")), ("contracts", s("c"))])).unwrap();
    seed_tasked_story(&mut rt, "sp1");

    // Sprint planned -> sprint_active false -> Start refused.
    let refused = rt.dispatch("Plan::Story.Start", attrs(&[("story", s("sp1"))]));
    assert!(refused.is_err(),
        "Start must be refused while the sprint is planned (sprint_active false), got: {:?}", refused);
    assert_eq!(field(&rt, "Story", "sp1", "sprint_active").as_deref(), Some("false"));
    assert_eq!(field(&rt, "Story", "sp1", "state").as_deref(), Some("tasked"),
        "a refused Start must leave the story tasked");

    // Activate -> seed_sprint_active fans MarkSprintActive over the member story -> Start succeeds.
    rt.dispatch("Plan::Sprint.Activate", attrs(&[("sprint", s("1"))])).unwrap();
    assert_eq!(field(&rt, "Story", "sp1", "sprint_active").as_deref(), Some("true"),
        "activation seeded the replicated flag");
    rt.dispatch("Plan::Story.Start", attrs(&[("story", s("sp1"))])).unwrap();
    assert_eq!(field(&rt, "Story", "sp1", "state").as_deref(), Some("started"),
        "once the sprint is active (flag seeded) the same story starts");
}
