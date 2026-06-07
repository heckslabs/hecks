//! i221-C where-fan-out runtime test
//!
//! Verifies that a `for_each:` sweep PARAMETERISED by the triggering
//! event filters — `for_each: { from: "Synapse.ByKind", where: { kind:
//! from_event(:want) } }` fires the receiving command only for the
//! records whose `kind` matches the event's `want`. This is the
//! capability the honest-blocked SEAM 1/3 stubs wait on : a sweep that
//! sees the event, not a sweep-all that fans out over every row.

use storehouse::parser;
use storehouse::runtime::{Event, Runtime, Value};
use std::collections::HashMap;

fn s(val: &str) -> Value { Value::Str(val.to_string()) }

fn attrs(pairs: &[(&str, Value)]) -> HashMap<String, Value> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

const BLUEBOOK: &str = r#"Hecks.bluebook "WhereSweepTest" do
  aggregate "Synapse" do
    identified_by :id
    attribute :id, String
    attribute :kind, String

    command "CreateSynapse" do
      role "Daemon"
      attribute :id, String
      attribute :kind, String
      then_set :id, to: :id
      then_set :kind, to: :kind
      emits "SynapseCreated"
    end

    query "ByKind" do
      where kind: :kind
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
      dispatch "Compostable.Mark", for_each: { from: "Synapse.ByKind", where: { kind: from_event(:want) } }, with: { id: from_iter(:id) }
    end
  end
end"#;

fn seed_and_birth() -> Runtime {
    let domain = parser::parse(BLUEBOOK);
    let mut rt = Runtime::boot(domain);
    // Three synapses : two warm, one cold.
    for (id, kind) in &[("a", "warm"), ("b", "cold"), ("c", "warm")] {
        rt.dispatch("CreateSynapse", attrs(&[("id", s(id)), ("kind", s(kind))])).unwrap();
    }
    assert_eq!(rt.all("Synapse").len(), 3, "three synapses seeded");
    rt.publish_synthetic_event(Event {
        name: "Started".into(),
        aggregate_type: "Sweeper".into(),
        aggregate_id: "1".into(),
        data: HashMap::new(),
    });
    rt
}

#[test]
fn parameterised_sweep_marks_only_matching_records() {
    let mut rt = seed_and_birth();
    // Beat carries want=warm : only the two warm synapses should be swept.
    rt.publish_synthetic_event(Event {
        name: "Beat".into(),
        aggregate_type: "Sweeper".into(),
        aggregate_id: "1".into(),
        data: attrs(&[("want", s("warm"))]),
    });
    let ids: std::collections::HashSet<String> = rt.all("Compostable").iter()
        .filter_map(|s| s.fields.get("id").map(|v| v.to_string())).collect();
    assert_eq!(ids.len(), 2, "only the two warm synapses, got {:?}", ids);
    assert!(ids.contains("a") && ids.contains("c"), "expected a,c got {:?}", ids);
    assert!(!ids.contains("b"), "cold synapse b must NOT be swept : {:?}", ids);
}

#[test]
fn parameterised_sweep_with_nonmatching_filter_marks_nothing() {
    let mut rt = seed_and_birth();
    // want=tepid matches no synapse : an honest empty fan-out.
    rt.publish_synthetic_event(Event {
        name: "Beat".into(),
        aggregate_type: "Sweeper".into(),
        aggregate_id: "1".into(),
        data: attrs(&[("want", s("tepid"))]),
    });
    assert_eq!(rt.all("Compostable").len(), 0,
        "no synapse matches want=tepid -> zero dispatches");
}
