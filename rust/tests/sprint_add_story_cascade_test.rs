//! P1.3 — Sprint owns the membership commit; the cascade sets Story.sprint.
//!
//! DDD: Sprint.AddStory is the SOLE commit path, gated intra-Sprint on planned (the
//! hard scope freeze). On StoryAddedToSprint the assign_story_on_sprint_add driven
//! adapter dispatches Story.AssignToSprint so Story.sprint (the single membership
//! truth, read by Story.BySprint) is set. No aggregate reads a sibling; the Sprint
//! stores no competing list.

use storehouse::corpus_loader::load_combined_domain;
use storehouse::hecksagon_parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(p: &[(&str, Value)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

const ASSIGN_HECKSAGON: &str = include_str!(
    "../../hecks_conception/aggregates/plan/hecksagons/assign_story_on_sprint_add.hecksagon"
);
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
fn boot() -> Runtime {
    let domain = load_combined_domain(&aggregates_dir());
    let hexes = vec![hecksagon_parser::parse(ASSIGN_HECKSAGON), hecksagon_parser::parse(SEED_HECKSAGON)];
    Runtime::boot_with_hecksagons(domain, None, hexes)
}

#[test]
fn sprint_add_story_sets_story_sprint_via_cascade() {
    let mut rt = boot();
    rt.dispatch("Plan::Sprint.Plan", attrs(&[("number", s("5")), ("goal", s("g")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.Capture", attrs(&[("ref", s("z1")), ("title", s("z1")), ("tier", s("1")), ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.AddStory", attrs(&[("id", s("5")), ("story", s("z1"))])).unwrap();
    assert_eq!(field(&rt, "Story", "z1", "sprint").as_deref(), Some("5"),
        "AddStory cascaded to set Story.sprint (the membership truth)");
}

#[test]
fn add_story_to_an_active_sprint_is_refused_by_the_freeze() {
    let mut rt = boot();
    rt.dispatch("Plan::Sprint.Plan", attrs(&[("number", s("6")), ("goal", s("g")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.Activate", attrs(&[("id", s("6"))])).unwrap();
    rt.dispatch("Plan::Story.Capture", attrs(&[("ref", s("z2")), ("title", s("z2")), ("tier", s("1")), ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
    let refused = rt.dispatch("Plan::Sprint.AddStory", attrs(&[("id", s("6")), ("story", s("z2"))]));
    assert!(refused.is_err(), "the hard freeze refuses committing a story to an active sprint");
}
