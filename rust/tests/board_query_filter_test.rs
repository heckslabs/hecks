//! Board query (#1 state-set + #4 active-sprint membership) filters end-to-end.
//!
//! Story.Board carries TWO where clauses :
//!   where state: { in: [untasked, tasked, started, ready_for_review] }   (#1)
//!   where sprint: { member_of: "Board.active_sprints" }                   (#4)
//! The state filter keeps only board-lifecycle stories ; the membership filter
//! (WhereOp::MemberOf, singleton cross-aggregate) keeps only stories whose
//! sprint is in the singleton Board's active_sprints list. This test boots an
//! ISOLATED runtime (behaviors share state, so query-count assertions belong
//! here, not in .behaviors) and proves both filters compose.

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

fn capture_tasked(rt: &mut Runtime, story: &str, sprint: &str) {
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s(story)), ("title", s(story)), ("tier", s("1")),
        ("summary", s("x")), ("target", s("y")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[("story", s(story)), ("sprint_ref", s(sprint))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("story", s(story))])).unwrap();
}

#[test]
fn board_filters_by_state_and_active_sprint_membership() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![]);

    // A board whose active set is { sprint 1 }.
    rt.dispatch("Plan::Board.Open", attrs(&[("name", s("b")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Board.PlaceSprint", attrs(&[("board", s("b")), ("sprint_ref", s("1"))])).unwrap();
    rt.dispatch("Plan::Board.ActivateSprint", attrs(&[
        ("board", s("b")), ("sprint_ref", s("1")),
        ("active_sprints", Value::List(vec![s("1")]))])).unwrap();

    capture_tasked(&mut rt, "ins", "1");   // tasked + sprint in active set -> ON board
    capture_tasked(&mut rt, "out", "2");   // tasked but sprint NOT active   -> OFF board
    // a deferred story on the active sprint -> excluded by the STATE filter
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s("def")), ("title", s("def")), ("tier", s("1")),
        ("summary", s("x")), ("target", s("y")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[("story", s("def")), ("sprint_ref", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.Defer", attrs(&[("story", s("def"))])).unwrap();

    let result = rt.resolve_query_qualified(Some("Plan"), "Story", "Board", &HashMap::new());
    let state = &result["state"];
    let refs: Vec<String> = match state.as_array() {
        Some(arr) => arr.iter().filter_map(|r| r["ref"].as_str().map(String::from)).collect(),
        None => state["ref"].as_str().map(|s| vec![s.to_string()]).unwrap_or_default(),
    };
    assert!(refs.contains(&"ins".to_string()),
        "a tasked story on an active sprint must be on the board ; got {:?}", refs);
    assert!(!refs.contains(&"out".to_string()),
        "a story whose sprint is NOT in active_sprints must be excluded ; got {:?}", refs);
    assert!(!refs.contains(&"def".to_string()),
        "a deferred story must be excluded by the state filter ; got {:?}", refs);
}
