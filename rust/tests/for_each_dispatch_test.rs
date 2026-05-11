//! i221-B sweep-dispatch runtime test
//!
//! Verifies that a `for_each:` dispatch fires once per record
//! returned by the sweep source, threading `from_iter(:field)`
//! through to each cascade.
//!
//! Setup : declare two aggregates — Synapse (with a query "all" that
//! returns every row) and Compostable (the sweep target). The PM
//! observes a synthetic Body event and dispatches Compostable.Mark
//! `for_each: { from: "Synapse.all" }`. We seed three Synapse rows ;
//! after the synthetic event, three Compostable rows should exist,
//! each carrying the iter id.

use storehouse::parser;
use storehouse::runtime::{Event, Runtime, Value};
use std::collections::HashMap;

fn s(val: &str) -> Value { Value::Str(val.to_string()) }

fn attrs(pairs: &[(&str, Value)]) -> HashMap<String, Value> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

const BLUEBOOK: &str = r#"Hecks.bluebook "SweepTest" do
  aggregate "Synapse" do
    identified_by :id
    attribute :id, String
    attribute :strength, Float

    command "CreateSynapse" do
      role "Daemon"
      attribute :id, String
      attribute :strength, Float
      then_set :id, to: :id
      then_set :strength, to: :strength
      emits "SynapseCreated"
    end

    query "all" do
    end
  end

  aggregate "Compostable" do
    identified_by :id
    attribute :id, String

    command "Mark" do
      role "Daemon"
      attribute :id, String
      then_set :id, to: :id
      emits "Marked"
    end
  end

  process_manager "Sweeper" do
    correlates_by :id
    starts_on    "Started"

    state "ready"

    on "Started", transition: { ready: :ready } do
    end

    on "Beat", transition: { ready: :ready } do
      dispatch "Compostable.Mark", for_each: { from: "Synapse.all" }, with: { id: from_iter(:id) }
    end
  end
end"#;

#[test]
fn for_each_dispatch_fires_once_per_record_with_iter_field() {
    let domain = parser::parse(BLUEBOOK);
    let mut rt = Runtime::boot(domain);

    // Seed three Synapse rows.
    for id in &["a", "b", "c"] {
        rt.dispatch(
            "CreateSynapse",
            attrs(&[("id", s(id)), ("strength", s("0.5"))]),
        ).unwrap();
    }
    assert_eq!(rt.all("Synapse").len(), 3, "three synapses seeded");

    // Birth the PM with a Started event.
    rt.publish_synthetic_event(Event {
        name: "Started".into(),
        aggregate_type: "Sweeper".into(),
        aggregate_id: "1".into(),
        data: HashMap::new(),
    });

    // Trigger the sweep — the PM should run for_each over Synapse.all
    // and fire Compostable.Mark for each record.
    rt.publish_synthetic_event(Event {
        name: "Beat".into(),
        aggregate_type: "Sweeper".into(),
        aggregate_id: "1".into(),
        data: HashMap::new(),
    });

    let composted = rt.all("Compostable");
    assert_eq!(composted.len(), 3,
        "expected 3 Compostable records (one per Synapse), got {}",
        composted.len());

    // Each Compostable should have an id matching one of the seeds.
    let ids: std::collections::HashSet<String> = composted
        .iter()
        .filter_map(|s| s.fields.get("id").map(|v| v.to_string()))
        .collect();
    assert!(ids.contains("a"), "missing id a in {:?}", ids);
    assert!(ids.contains("b"), "missing id b in {:?}", ids);
    assert!(ids.contains("c"), "missing id c in {:?}", ids);
}

#[test]
fn for_each_over_empty_source_dispatches_nothing() {
    let domain = parser::parse(BLUEBOOK);
    let mut rt = Runtime::boot(domain);

    // Birth the PM ; no synapses seeded.
    rt.publish_synthetic_event(Event {
        name: "Started".into(),
        aggregate_type: "Sweeper".into(),
        aggregate_id: "1".into(),
        data: HashMap::new(),
    });
    rt.publish_synthetic_event(Event {
        name: "Beat".into(),
        aggregate_type: "Sweeper".into(),
        aggregate_id: "1".into(),
        data: HashMap::new(),
    });

    assert_eq!(rt.all("Compostable").len(), 0,
        "empty sweep source must dispatch nothing");
}
