//! causation_trace_tests — the Phase-4 lineage traversal kernel
//!
//! Asserts (1) CausationTrace walks causation_id from a leaf event up to its
//! root cause, in order, over a seeded Event repo, and (2) the Phase-4 stamp
//! data path : record_event_append notes the last event per aggregate
//! (note_last_event) and a cascade resolves its cause to it (cause_for_cascade),
//! so causation_id is no longer empty on live cascades ; and (3) the FULL
//! end-to-end : a real policy cascade through dispatch() (heki-backed runtime,
//! event sourcing ON) stamps causation_id on the cascaded command's recorded
//! event == the triggering event's id — proving the durable chain
//! (record_event_append notes the trigger -> record_cascade_run persists it on
//! the run -> the pump primes the map -> the cascaded record_event_append stamps).

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

// END-TO-END : a real cascade through dispatch() stamps causation_id on the
// cascaded command's recorded events. Boots a heki-backed runtime from a temp
// dir holding the REAL Event + CascadeRun chapters + a minimal policy cascade
// (Trigger.Fire -> Fired -> Target.Land), event sourcing ON, then reads the
// Event store and asserts Target.Land's event carries causation_id ==
// Trigger.Fire's event id. Proves the DURABLE chain end to end :
// record_event_append notes the trigger -> record_cascade_run persists it on
// the run -> the pump primes the map -> the cascaded command's
// record_event_append stamps it. (Default-heki Event upserts each Append into
// the Event store, so no AppendLog/merge wiring is needed to observe it.)
#[test]
fn cascade_stamps_causation_end_to_end() {
    use std::collections::HashMap;
    // Post-extraction the engine no longer sits beside hecks_conception, so
    // resolve the live framework chapters via HECKS_CONCEPTION_DIR (the gate
    // sets it), falling back to the standard sibling checkout (storehouse
    // beside hecks) for a bare local run.
    let conception = std::env::var("HECKS_CONCEPTION_DIR").unwrap_or_else(|_| {
        format!("{}/../../hecks/hecks_conception", env!("CARGO_MANIFEST_DIR"))
    });
    let fw = format!("{}/aggregates/framework", conception);
    let dir = std::env::temp_dir().join(format!("caus_e2e_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::copy(
        format!("{}/event_sourcing/event_sourcing.bluebook", fw),
        dir.join("event_sourcing.bluebook"),
    )
    .unwrap();
    std::fs::copy(
        format!("{}/cascade/cascade_run.bluebook", fw),
        dir.join("cascade_run.bluebook"),
    )
    .unwrap();
    let cascade_bb = r#"Hecks.bluebook "CausTest" do
core
aggregate "Trigger" do
identified_by :name
attribute :name,  Name
attribute :fired, Fired, default: "no"
value_object "Name" do
  attribute :value, String
end
value_object "Fired" do
  attribute :value, String
end
command "Fire" do
  role "System"
  goal "Fire so the policy cascades Target.Land"
  attribute :name, Name
  then_set :fired, to: "yes"
  emits "Fired"
end
end
aggregate "Target" do
identified_by :name
attribute :name,   Name
attribute :landed, Landed, default: "no"
value_object "Name" do
  attribute :value, String
end
value_object "Landed" do
  attribute :value, String
end
command "Land" do
  role "System"
  goal "Record the cascaded landing"
  attribute :name, Name
  then_set :landed, to: "yes"
  emits "Landed"
end
end
policy "LandOnFired" do
on "Trigger.Fired"
trigger "CausTest::Target.Land"
with "name", "t1"
end
end
"#;
    std::fs::write(dir.join("caustest.bluebook"), cascade_bb).unwrap();

    let domain = crate::corpus_loader::load_combined_domain(dir.to_str().unwrap());
    let data = dir.join("data").to_string_lossy().into_owned();
    std::env::set_var("HECKS_EVENT_SOURCING", "1");
    let mut rt = Runtime::boot_with_data_dir(domain, Some(data));
    let mut attrs = HashMap::new();
    attrs.insert("name".to_string(), Value::Str("t1".to_string()));
    rt.dispatch("CausTest::Trigger.Fire", attrs).expect("Fire dispatch");
    std::env::remove_var("HECKS_EVENT_SOURCING");

    let events = rt.all_qualified(Some("EventSourcing"), "Event");
    let agg = |s: &AggregateState| s.get("aggregate_name").to_string();
    let trigger_ids: std::collections::HashSet<String> = events
        .iter()
        .filter(|s| agg(s) == "Trigger")
        .map(|s| s.id.clone())
        .collect();
    let targets: Vec<&AggregateState> = events
        .iter()
        .filter(|s| agg(s) == "Target")
        .copied()
        .collect();
    assert!(!trigger_ids.is_empty(), "Trigger.Fire recorded at least one event");
    assert!(!targets.is_empty(), "the cascade recorded a Target.Land event");
    for t in &targets {
        let caus = t.get("causation_id").to_string();
        assert!(!caus.is_empty(), "cascaded Target event must carry causation_id");
        assert!(
            trigger_ids.contains(&caus),
            "Target.causation ({}) must equal a Trigger event id {:?}",
            caus,
            trigger_ids
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
}
