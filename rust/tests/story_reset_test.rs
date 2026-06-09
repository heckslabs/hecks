//! P1.4 — move = reset. A stakeholder reset reverts an in-play story AND reopens its
//! tasks (not deletes them). Story.Reset is local (started -> tasked, sprint_active ->
//! false) ; the reset_story_tasks driven adapter fans Task.Reopen over Task.ForStory,
//! and IncrementOnTaskReopened rebuilds pending_task_count — which now fires because
//! adapter-dispatched commands drain policies (the cross adapter->policy cascade fix).
//! Repo revert is manual.

use storehouse::corpus_loader::load_combined_domain;
use storehouse::hecksagon_parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(p: &[(&str, Value)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}
const RESET_HEX: &str = include_str!(
    "../../hecks_conception/aggregates/plan/hecksagons/reset_story_tasks.hecksagon"
);
fn aggregates_dir() -> String {
    format!("{}/../hecks_conception/aggregates", env!("CARGO_MANIFEST_DIR"))
}
fn field(rt: &Runtime, agg: &str, id: &str, f: &str) -> Option<String> {
    rt.all_qualified(Some("Plan"), agg).into_iter().find(|r| r.id == id)
        .and_then(|r| r.fields.get(f).map(|v| v.to_string()))
}

#[test]
fn story_reset_reverts_and_reopens_tasks() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![hecksagon_parser::parse(RESET_HEX)]);

    rt.dispatch("Plan::Sprint.Plan", attrs(&[("number", s("1")), ("goal", s("g")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.RatifyContracts", attrs(&[("id", s("1")), ("contracts", s("c"))])).unwrap();
    rt.dispatch("Plan::Sprint.Activate", attrs(&[("id", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.Capture", attrs(&[("ref", s("r1")), ("title", s("r1")), ("tier", s("1")), ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[("id", s("r1")), ("sprint_ref", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.MarkSprintActive", attrs(&[("id", s("r1"))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("id", s("r1"))])).unwrap();
    rt.dispatch("Plan::Task.Add", attrs(&[("id", s("t1")), ("story", s("r1")), ("order", s("1")), ("description", s("d"))])).unwrap();
    rt.dispatch("Plan::Task.Complete", attrs(&[("id", s("t1"))])).unwrap();
    assert_eq!(field(&rt, "Story", "r1", "pending_task_count").as_deref(), Some("0"));
    rt.dispatch("Plan::Story.Start", attrs(&[("story", s("r1"))])).unwrap();
    assert_eq!(field(&rt, "Story", "r1", "state").as_deref(), Some("started"));

    rt.dispatch("Plan::Story.Reset", attrs(&[("id", s("r1"))])).unwrap();
    assert_eq!(field(&rt, "Story", "r1", "state").as_deref(), Some("tasked"), "reverted started -> tasked");
    assert_eq!(field(&rt, "Story", "r1", "sprint_active").as_deref(), Some("false"), "sprint_active cleared");
    assert_eq!(field(&rt, "Task", "t1", "status").as_deref(), Some("pending"), "task REOPENED, not deleted");
    assert_eq!(field(&rt, "Story", "r1", "pending_task_count").as_deref(), Some("1"), "count rebuilt via IncrementOnTaskReopened (adapter->policy cascade)");
}
