//! P1.4a — move = reset, the LOCAL revert. A stakeholder reset reverts an in-play
//! story to the start of the lifecycle : state started -> tasked, sprint_active ->
//! false. No aggregate reads a sibling. Reopening the story's tasks (P1.4b) is
//! deferred — it needs a Task.Reopen fan-out, and policies do not currently cascade
//! off driven-adapter-dispatched commands (a direct Task.Reopen bumps the count, the
//! hecksagon path does not), so pending_task_count would go stale. Repo revert is manual.

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

#[test]
fn story_reset_reverts_started_to_tasked_and_clears_sprint_active() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![]);

    rt.dispatch("Plan::Sprint.Plan", attrs(&[("number", s("1")), ("goal", s("g")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.RatifyContracts", attrs(&[("id", s("1")), ("contracts", s("c"))])).unwrap();
    rt.dispatch("Plan::Sprint.Activate", attrs(&[("id", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.Capture", attrs(&[("ref", s("r1")), ("title", s("r1")), ("tier", s("1")), ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[("id", s("r1")), ("sprint_ref", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.MarkSprintActive", attrs(&[("id", s("r1"))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("id", s("r1"))])).unwrap();
    rt.dispatch("Plan::Story.Start", attrs(&[("story", s("r1"))])).unwrap();
    assert_eq!(field(&rt, "Story", "r1", "state").as_deref(), Some("started"));

    rt.dispatch("Plan::Story.Reset", attrs(&[("id", s("r1"))])).unwrap();
    assert_eq!(field(&rt, "Story", "r1", "state").as_deref(), Some("tasked"), "reverted started -> tasked");
    assert_eq!(field(&rt, "Story", "r1", "sprint_active").as_deref(), Some("false"), "sprint_active cleared");

    // a reset story cannot Start again until re-seeded (sprint_active false).
    let refused = rt.dispatch("Plan::Story.Start", attrs(&[("story", s("r1"))]));
    assert!(refused.is_err(), "a reset story refuses Start until its sprint_active is re-seeded");
}
