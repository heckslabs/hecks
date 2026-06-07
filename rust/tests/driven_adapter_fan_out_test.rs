//! i221-C Route B — where-fan-out on a DRIVEN ADAPTER (the stateless
//! reaction shape SEAM 1/3 use). A real command (Bell.Ring) emits the
//! trigger event ; the driven adapter's `dispatch ... for_each: { from:
//! "Q", where: { f: "{evt}" } }` runs the event-filtered query and fires
//! the command once per match, `{record_field}` carrying each match's key.

use storehouse::{hecksagon_parser, parser};
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(p: &[(&str, Value)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

const BLUEBOOK: &str = r#"Hecks.bluebook "FanOutB" do
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
  aggregate "Bell" do
    identified_by :id
    attribute :id, String
    attribute :want, String
    command "Ring" do
      role "Daemon"
      attribute :id, String
      attribute :want, String
      then_set :id, to: :id
      then_set :want, to: :want
      emits "Rung"
    end
  end
end"#;

const HECKSAGON: &str = r#"Hecks.hecksagon "Reaper" do
  adapter "ReapByKind" do
    driven on "Bell.Rung" do |event|
      dispatch "Compostable.Mark", for_each: { from: "Synapse.ByKind", where: { kind: "{want}" } }, id: "{id}"
    end
  end
end
"#;

fn booted() -> Runtime {
    let domain = parser::parse(BLUEBOOK);
    let hex = hecksagon_parser::parse(HECKSAGON);
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![hex]);
    for (id, kind) in &[("a", "warm"), ("b", "cold"), ("c", "warm")] {
        rt.dispatch("CreateSynapse", attrs(&[("id", s(id)), ("kind", s(kind))])).unwrap();
    }
    assert_eq!(rt.all("Synapse").len(), 3);
    rt
}

#[test]
fn driven_adapter_sweep_marks_only_matching_records() {
    let mut rt = booted();
    rt.dispatch("Ring", attrs(&[("id", s("bell1")), ("want", s("warm"))])).unwrap();
    let ids: std::collections::HashSet<String> = rt.all("Compostable").iter()
        .filter_map(|r| r.fields.get("id").map(|v| v.to_string())).collect();
    assert_eq!(ids.len(), 2, "only warm synapses swept, got {:?}", ids);
    assert!(ids.contains("a") && ids.contains("c"), "expected a,c got {:?}", ids);
    assert!(!ids.contains("b"), "cold b must not be swept: {:?}", ids);
}

#[test]
fn driven_adapter_sweep_with_no_match_marks_nothing() {
    let mut rt = booted();
    rt.dispatch("Ring", attrs(&[("id", s("bell1")), ("want", s("tepid"))])).unwrap();
    assert_eq!(rt.all("Compostable").len(), 0, "no match -> zero dispatches");
}
