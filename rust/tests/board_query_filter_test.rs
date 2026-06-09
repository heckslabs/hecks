//! Board query filters end-to-end, DDD form. Story.Board carries TWO where clauses,
//! BOTH aggregate-local reads on the Story's own state :
//!   where state: { in: [untasked, tasked, started, ready_for_review] }
//!   where sprint_active: true   (the REPLICATED flag — was the cross-agg MemberOf join)
//! "On the board" = in an active sprint = sprint_active true. No sibling read. This boots
//! an ISOLATED runtime (behaviors share state, so count assertions live here).

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

fn capture_tasked(rt: &mut Runtime, story: &str, sprint: &str, on_board: bool) {
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s(story)), ("title", s(story)), ("tier", s("1")),
        ("summary", s("x")), ("target", s("y")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[("story", s(story)), ("sprint_ref", s(sprint))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("story", s(story))])).unwrap();
    if on_board {
        rt.dispatch("Plan::Story.MarkSprintActive", attrs(&[("story", s(story))])).unwrap();
    }
}

#[test]
fn board_filters_by_state_and_sprint_active_flag() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![]);

    capture_tasked(&mut rt, "ins", "1", true);    // tasked + sprint active -> ON board
    capture_tasked(&mut rt, "out", "2", false);   // tasked but sprint NOT active -> OFF board
    // a deferred story whose sprint IS active -> excluded by the STATE filter
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s("def")), ("title", s("def")), ("tier", s("1")),
        ("summary", s("x")), ("target", s("y")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[("story", s("def")), ("sprint_ref", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.MarkSprintActive", attrs(&[("story", s("def"))])).unwrap();
    rt.dispatch("Plan::Story.Defer", attrs(&[("story", s("def"))])).unwrap();

    let result = rt.resolve_query_qualified(Some("Plan"), "Story", "Board", &HashMap::new());
    let state = &result["state"];
    let refs: Vec<String> = match state.as_array() {
        Some(arr) => arr.iter().filter_map(|r| r["ref"].as_str().map(String::from)).collect(),
        None => state["ref"].as_str().map(|s| vec![s.to_string()]).unwrap_or_default(),
    };
    assert!(refs.contains(&"ins".to_string()), "a tasked story with sprint_active must be on the board ; got {:?}", refs);
    assert!(!refs.contains(&"out".to_string()), "a story with sprint_active false must be excluded ; got {:?}", refs);
    assert!(!refs.contains(&"def".to_string()), "a deferred story must be excluded by the state filter ; got {:?}", refs);
}
