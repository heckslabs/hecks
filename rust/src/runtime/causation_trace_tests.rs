//! causation_trace_tests — the Phase-4 lineage traversal kernel
//!
//! Asserts (1) CausationTrace walks causation_id from a leaf event up to its
//! root cause, in order, over a seeded Event repo, and (2) the Phase-4 stamp
//! data path : record_event_append notes the last event per aggregate
//! (note_last_event) and a cascade resolves its cause to it (cause_for_cascade),
//! so causation_id is no longer empty on live cascades. The full gated
//! record → cascade → merge integration runs in the live runtime
//! (HECKS_EVENT_SOURCING=1) ; here the deterministic data path is unit-tested.

use super::*;

const BLUEBOOK: &str = r#"Hecks.bluebook "Lineage" do
  core
  aggregate "Event" do
    identified_by :event_id
    attribute :event_id, EventId
    attribute :causation_id, CausationId
    value_object "EventId" do
      attribute :value, String
    end
    value_object "CausationId" do
      attribute :value, String
    end
    query "CausationTrace" do |event_id|
      description "walk the causation chain from this event up to its root cause"
    end
  end
end
"#;

fn ev(id: &str, cause: &str) -> AggregateState {
    let mut s = AggregateState::new(id);
    s.set("event_id", Value::Str(id.to_string()));
    s.set("causation_id", Value::Str(cause.to_string()));
    s
}

fn boot_with(chain: &[(&str, &str)]) -> Runtime {
    let domain = crate::parser::parse(BLUEBOOK);
    let mut rt = Runtime::boot(domain);
    let ctx = rt
        .domain
        .aggregates
        .iter()
        .find(|a| a.name == "Event")
        .and_then(|a| a.context.clone());
    let key = repo_key(ctx.as_deref(), "Event");
    let repo = rt.repositories.get_mut(&key).expect("Event repo present");
    for (id, cause) in chain {
        repo.seed_record(ev(id, cause));
    }
    rt
}

fn trace_ids(rt: &Runtime, leaf: &str) -> Vec<String> {
    let mut attrs = std::collections::HashMap::new();
    attrs.insert("event_id".to_string(), leaf.to_string());
    let result = rt.resolve_query("CausationTrace", &attrs);
    result
        .get("state")
        .and_then(|s| s.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|e| e.get("event_id").and_then(|v| v.as_str()).map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

#[test]
fn walks_chain_from_leaf_to_root() {
    // e1 (root) <- e2 <- e3 (leaf) : tracing from e3 yields e3, e2, e1.
    let rt = boot_with(&[("e1", ""), ("e2", "e1"), ("e3", "e2")]);
    assert_eq!(
        trace_ids(&rt, "e3"),
        vec!["e3".to_string(), "e2".to_string(), "e1".to_string()]
    );
}

#[test]
fn stops_at_root_cause() {
    // A root event (empty causation_id) traces to just itself.
    let rt = boot_with(&[("e1", "")]);
    assert_eq!(trace_ids(&rt, "e1"), vec!["e1".to_string()]);
}

#[test]
fn missing_link_terminates_the_walk() {
    // e2's parent e1 was never recorded : the walk yields e2 then stops.
    let rt = boot_with(&[("e2", "e1")]);
    assert_eq!(trace_ids(&rt, "e2"), vec!["e2".to_string()]);
}

#[test]
fn cycle_is_guarded() {
    // e1 <-> e2 cycle must terminate, visiting each at most once.
    let rt = boot_with(&[("e1", "e2"), ("e2", "e1")]);
    assert_eq!(trace_ids(&rt, "e1").len(), 2);
}

#[test]
fn unknown_root_yields_empty_trace() {
    let rt = boot_with(&[("e1", "")]);
    assert!(trace_ids(&rt, "nope").is_empty());
}

#[test]
fn cause_for_cascade_resolves_to_last_event_of_upstream() {
    // The Phase-4 stamp path : record_event_append notes the last event_id per
    // aggregate ; a cascade off that aggregate resolves its cause to it.
    let mut rt = boot_with(&[]);
    rt.note_last_event("Order", "o1", "shard-7");
    assert_eq!(
        rt.cause_for_cascade(&Some(("Order".to_string(), "o1".to_string()))),
        "shard-7"
    );
    // Latest write wins — a command's last delta-event is the representative cause.
    rt.note_last_event("Order", "o1", "shard-9");
    assert_eq!(
        rt.cause_for_cascade(&Some(("Order".to_string(), "o1".to_string()))),
        "shard-9"
    );
}

#[test]
fn cause_for_cascade_is_empty_for_root_and_unknown() {
    let mut rt = boot_with(&[]);
    rt.note_last_event("Order", "o1", "shard-7");
    // Root dispatch (no hint) → empty cause → CausationTrace stops.
    assert_eq!(rt.cause_for_cascade(&None), "");
    // Cascade off an aggregate that recorded no events → empty.
    assert_eq!(
        rt.cause_for_cascade(&Some(("Pizza".to_string(), "p1".to_string()))),
        ""
    );
}
