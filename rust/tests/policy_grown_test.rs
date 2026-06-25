//! The grown plain Policy executing end-to-end (deciderate Layer 0b):
//! where-GUARD, for_each FAN-OUT of the primary trigger, and EXTRA dispatches
//! (multiple reactions). Each test owns its bluebook so policies on the same
//! event never cross-fire. Memory persistence by default (no hecksagon).

use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::{HashMap, HashSet};

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), s(v))).collect()
}
fn ids(rt: &Runtime, agg: &str) -> HashSet<String> {
    rt.all(agg).iter().filter_map(|r| r.fields.get("id").map(|v| v.to_string())).collect()
}

const GUARD_SRC: &str = r#"Hecks.bluebook "PolGuard" do
  aggregate "Bell" do
    identified_by :id
    attribute :id, String
    attribute :want, String
    command "Ring" do
      attribute :id, String
      attribute :want, String
      then_set :id, to: :id
      then_set :want, to: :want
      emits "Rung"
    end
  end
  aggregate "Mark" do
    identified_by :id
    attribute :id, String
    command "Create" do
      attribute :id, String
      then_set :id, to: :id
      emits "Created"
    end
  end
  policy "GuardedMark" do
    on "Rung"
    where want: "go"
    trigger "Mark.Create"
  end
end"#;

#[test]
fn where_guard_fires_only_when_event_matches() {
    let mut rt = Runtime::boot_with_hecksagons(parser::parse(GUARD_SRC), None, vec![]);
    // want == "go" -> guard passes -> Mark b1 created.
    rt.dispatch("Ring", attrs(&[("id", "b1"), ("want", "go")])).unwrap();
    // want == "stop" -> guard fails -> no Mark.
    rt.dispatch("Ring", attrs(&[("id", "b2"), ("want", "stop")])).unwrap();
    let marks = ids(&rt, "Mark");
    assert_eq!(marks, HashSet::from(["b1".to_string()]), "only the go-guarded ring marks; got {:?}", marks);
}

const FANOUT_SRC: &str = r#"Hecks.bluebook "PolFanOut" do
  aggregate "Synapse" do
    identified_by :id
    attribute :id, String
    attribute :kind, String
    command "CreateSynapse" do
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
      attribute :id, String
      attribute :want, String
      then_set :id, to: :id
      then_set :want, to: :want
      emits "Rung"
    end
  end
  policy "FanOutMark" do
    on "Rung"
    for_each: { from: "Synapse.ByKind", where: { kind: from_event(:want) } }
    trigger "Compostable.Mark"
  end
end"#;

#[test]
fn for_each_fans_out_the_primary_trigger_per_swept_record() {
    let mut rt = Runtime::boot_with_hecksagons(parser::parse(FANOUT_SRC), None, vec![]);
    for (id, kind) in &[("a", "warm"), ("b", "cold"), ("c", "warm")] {
        rt.dispatch("CreateSynapse", attrs(&[("id", id), ("kind", kind)])).unwrap();
    }
    // Ring(want=warm) -> sweep Synapse.ByKind(kind=warm) -> a,c -> Mark each.
    rt.dispatch("Ring", attrs(&[("id", "bell1"), ("want", "warm")])).unwrap();
    let marked = ids(&rt, "Compostable");
    assert_eq!(marked, HashSet::from(["a".to_string(), "c".to_string()]),
        "only warm synapses swept; got {:?}", marked);
}

const MULTI_SRC: &str = r#"Hecks.bluebook "PolMulti" do
  aggregate "Bell" do
    identified_by :id
    attribute :id, String
    command "Ring" do
      attribute :id, String
      then_set :id, to: :id
      emits "Rung"
    end
  end
  aggregate "A" do
    identified_by :id
    attribute :id, String
    command "Create" do
      attribute :id, String
      then_set :id, to: :id
      emits "ACreated"
    end
  end
  aggregate "B" do
    identified_by :id
    attribute :id, String
    command "Create" do
      attribute :id, String
      then_set :id, to: :id
      emits "BCreated"
    end
  end
  policy "Multi" do
    on "Rung"
    trigger "A.Create"
    dispatch "B.Create", with: { id: from_event(:id) }
  end
end"#;

#[test]
fn extra_dispatch_fires_a_second_reaction() {
    let mut rt = Runtime::boot_with_hecksagons(parser::parse(MULTI_SRC), None, vec![]);
    rt.dispatch("Ring", attrs(&[("id", "x1")])).unwrap();
    // primary trigger -> A.Create(x1) ; extra dispatch -> B.Create(x1).
    assert_eq!(ids(&rt, "A"), HashSet::from(["x1".to_string()]), "primary trigger A");
    assert_eq!(ids(&rt, "B"), HashSet::from(["x1".to_string()]), "extra dispatch B");
}
