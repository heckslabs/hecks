//! LINEAGE : every event in ONE business flow shares a correlation_id. A flow is
//! a root command PLUS every cascade it triggers — so `Trigger.Fire` and the
//! `Target.Land` its policy cascades from `Fired` both carry the SAME
//! correlation_id, and the Log's ByCorrelation facet can gather the whole saga.
//!
//! Before this slice correlation_id was PER-EVENT (`{type}::{id}::{event}`), so
//! the root `Fired` and the cascaded `Landed` carried DIFFERENT ids and no query
//! could reassemble the flow. This test asserts they now share one minted `corr-`
//! id, and that a SECOND, independent Fire opens a DISTINCT flow — the two proofs
//! that make the facet meaningful.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use storehouse::runtime::{AggregateState, Runtime, Value};
use storehouse::{corpus_loader, embed};

fn conception() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("hecks_conception")
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap_or_else(|e| panic!("read {:?}: {}", from, e)) {
        let entry = entry.unwrap();
        if entry.file_type().unwrap().is_file() {
            std::fs::copy(entry.path(), to.join(entry.file_name())).unwrap();
        }
    }
}

// A minimal event_sourced saga : Trigger.Fire -> Fired -> (policy) -> Target.Land
// -> Landed. Two aggregates, one causal cascade — one FLOW.
const SAGA: &str = r#"Hecks.bluebook "Saga" do
  core
  aggregate "Trigger" do
    identified_by :name
    attribute :name, Name
    attribute :fired, Fired, default: "no"
    value_object "Name" do
      attribute :value, String
    end
    value_object "Fired" do
      attribute :value, String
    end
    command "Fire" do
      role "System"
      attribute :name, Name
      then_set :fired, to: "yes"
      emits "Fired"
    end
  end
  aggregate "Target" do
    identified_by :name
    attribute :name, Name
    attribute :landed, Landed, default: "no"
    value_object "Name" do
      attribute :value, String
    end
    value_object "Landed" do
      attribute :value, String
    end
    command "Land" do
      role "System"
      attribute :name, Name
      then_set :landed, to: "yes"
      emits "Landed"
    end
  end
  policy "LandOnFired" do
    on "Trigger.Fired"
    trigger "Saga::Target.Land"
    with "name", "t1"
  end
end
"#;

const SAGA_HEX: &str = r#"Hecks.hecksagon "Saga" do
  Saga::Trigger.persisted_by("Heki")
  Saga::Trigger.event_sourced
  Saga::Target.persisted_by("Heki")
  Saga::Target.event_sourced
end
"#;

fn s(v: &str) -> Value {
    Value::Str(v.to_string())
}

/// Boot the saga against the REAL framework substrate in its own temp root, so
/// two tests can run the same fixture concurrently without sharing a data dir.
fn boot_saga(root_name: &str) -> (Runtime, PathBuf) {
    let c = conception();
    let root = std::env::temp_dir().join(root_name);
    let _ = std::fs::remove_dir_all(&root);

    let fw = root.join("aggregates").join("framework");
    copy_dir(&c.join("aggregates/framework/adapters"), &fw.join("adapters"));
    copy_dir(&c.join("aggregates/framework/families"), &fw.join("families"));
    copy_dir(
        &c.join("aggregates/framework/event_sourcing/bluebook"),
        &fw.join("event_sourcing/bluebook"),
    );
    copy_dir(&c.join("aggregates/framework/hexagon/bluebook"), &fw.join("hexagon/bluebook"));

    let sd = fw.join("saga/bluebook");
    std::fs::create_dir_all(&sd).unwrap();
    std::fs::write(sd.join("saga.bluebook"), SAGA).unwrap();
    std::fs::write(sd.join("saga.hecksagon"), SAGA_HEX).unwrap();

    let agg_dir = root.join("aggregates");
    let agg_dir_s = agg_dir.to_str().unwrap();
    let domain = corpus_loader::load_combined_domain(agg_dir_s);
    let hecksagons = embed::load_hecksagons(agg_dir_s);
    let data = root.join("data").to_string_lossy().into_owned();
    let rt = Runtime::boot_with_framework_dir(domain, Some(data), hecksagons, &agg_dir);
    (rt, root)
}

fn event_name(e: &AggregateState) -> String {
    match e.get("event_name") {
        Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        _ => String::new(),
    }
}
fn correlation(e: &AggregateState) -> String {
    match e.get("correlation_id") {
        Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        Value::Str(v) => v.clone(),
        other => other.to_string(),
    }
}

#[test]
fn one_flow_shares_a_correlation_id_across_the_cascade() {
    let (mut rt, root) = boot_saga("es_correlation_proof");

    // TWO flows, dispatched before one read : Fire(t1) cascades to Land(t1) via the
    // LandOnFired policy (pump settles in-process before dispatch returns) ; Fire(t2)
    // is a second, independent flow (a fresh Trigger, so it records a state change).
    let mut fire = std::collections::HashMap::new();
    fire.insert("name".to_string(), s("t1"));
    rt.dispatch("Saga::Trigger.Fire", fire).expect("Fire(t1) cascades to Land");
    let mut fire2 = std::collections::HashMap::new();
    fire2.insert("name".to_string(), s("t2"));
    rt.dispatch("Saga::Trigger.Fire", fire2).expect("Fire(t2) — a second flow");

    let events = rt.all_qualified(Some("EventSourcing"), "Event");
    let id_of = |e: &AggregateState| match e.get("aggregate_id") {
        Value::Str(v) => v.clone(),
        Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        other => other.to_string(),
    };
    // The correlations carried by EVERY row matching agg/id/event. A set, not a
    // `find` : the policy cascades Land onto Target `t1` for BOTH flows, so
    // `Target/t1/Landed` legitimately has one row PER FLOW and picking "the
    // first" would assert on whichever happened to be written first.
    let corrs_for = |agg: &str, id: &str, ev: &str| -> HashSet<String> {
        let found: HashSet<String> = events
            .iter()
            .filter(|e| e.get("aggregate_name").to_string() == agg && id_of(e) == id && event_name(e) == ev)
            .map(|e| correlation(e))
            .collect();
        assert!(!found.is_empty(), "missing {agg}/{id}/{ev} event-row");
        found
    };
    let one = |s: HashSet<String>, what: &str| -> String {
        assert_eq!(s.len(), 1, "expected exactly one correlation for {what}, got {s:?}");
        s.into_iter().next().unwrap()
    };

    // Each flow has exactly ONE root event-row : its own Trigger's `Fired`.
    let corr1 = one(corrs_for("Trigger", "t1", "Fired"), "flow 1 root (Trigger t1 / Fired)");
    let corr2 = one(corrs_for("Trigger", "t2", "Fired"), "flow 2 root (Trigger t2 / Fired)");

    // (1) Both are MINTED per-flow ids, not the per-event `{type}::{id}::{event}`
    // fallback, and (2) they are DISTINCT — flows do not bleed together.
    assert!(
        corr1.starts_with("corr-") && corr2.starts_with("corr-"),
        "both flows carry minted per-flow ids (corr-…), got {corr1} and {corr2}",
    );
    assert_ne!(corr1, corr2, "two independent roots must open two distinct flows");

    // (3) THE CASCADE INHERITS — the heart of the slice. The policy cascades
    // `Land` onto Target `t1` for BOTH flows, so `Target/t1/Landed` holds exactly
    // one row per flow, and the correlation on each is its OWN flow's id. The
    // per-event form would have given both rows the same `Target::t1::Landed`.
    //
    // This also guards the log's COMPLETENESS : flow 2's `Land` changes no state
    // (t1 already landed), so it produces no delta — and an empty-delta early
    // return in `record_event_append` would silently drop its event-row and leave
    // this set at {corr1} alone. A missing event fails here.
    assert_eq!(
        corrs_for("Target", "t1", "Landed"),
        HashSet::from([corr1.clone(), corr2.clone()]),
        "each flow's cascaded Landed must carry ITS OWN flow's correlation — one row per flow",
    );

    // (4) It is the whole flow, not just the event-rows : every row the root
    // aggregate recorded (delta-rows included) carries the flow's one id.
    let trigger_t1: HashSet<String> = events
        .iter()
        .filter(|e| e.get("aggregate_name").to_string() == "Trigger" && id_of(e) == "t1")
        .map(|e| correlation(e))
        .collect();
    assert_eq!(
        trigger_t1, HashSet::from([corr1.clone()]),
        "every row of flow 1's root aggregate shares its one correlation, got {trigger_t1:?}",
    );

    let _ = std::fs::remove_dir_all(&root);
}

/// LINEAGE, forward : the consequence tree BITES on the live Log. The seeded unit
/// tests (runtime::consequence_tree_tests) prove the traversal's SHAPE — fan-out,
/// depth, sibling determinism, cycle guard — over chains a real cascade cannot
/// produce. This proves the other half : that the field it walks is actually
/// stamped by a live policy cascade, so asking the root event "what did you
/// cause?" reaches the far side of the saga.
#[test]
fn the_consequence_tree_reaches_the_cascade_on_the_live_log() {
    let (mut rt, root) = boot_saga("es_consequence_live_proof");

    let mut fire = std::collections::HashMap::new();
    fire.insert("name".to_string(), s("t1"));
    rt.dispatch("Saga::Trigger.Fire", fire).expect("Fire(t1) cascades to Land");

    let event_id_of = |e: &AggregateState| match e.get("event_id") {
        Value::Str(v) => v.clone(),
        Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        other => other.to_string(),
    };
    let fired_id: String = {
        let events = rt.all_qualified(Some("EventSourcing"), "Event");
        events
            .iter()
            .find(|e| e.get("aggregate_name").to_string() == "Trigger" && event_name(e) == "Fired")
            .map(|e| event_id_of(e))
            .expect("a Fired event-row on the live log")
    };
    assert!(!fired_id.is_empty(), "the Fired event-row must carry an event_id");

    let mut attrs = std::collections::HashMap::new();
    attrs.insert("event_id".to_string(), fired_id.clone());
    let result = rt.resolve_query("ConsequenceTree", &attrs);
    let rows = result.get("state").and_then(|v| v.as_array()).cloned().unwrap_or_default();

    // Rooted at Fired, at depth 0.
    assert!(!rows.is_empty(), "ConsequenceTree returned nothing for {fired_id}");
    assert_eq!(rows[0].get("depth").and_then(|d| d.as_i64()), Some(0), "the queried event roots the tree");

    // And it REACHES the cascade : the Landed event-row the policy caused is in
    // the tree, below the root. Before causation_id was stamped on live cascades
    // this tree would have been the root alone.
    let reached_landed = rows.iter().any(|r| {
        let is_landed = r.get("event_name").map(|v| v.to_string().contains("Landed")).unwrap_or(false);
        let below_root = r.get("depth").and_then(|d| d.as_i64()).unwrap_or(0) > 0;
        is_landed && below_root
    });
    assert!(
        reached_landed,
        "the cascade's Landed event must appear below the root of Fired's consequence tree — got {rows:#?}",
    );

    let _ = std::fs::remove_dir_all(&root);
}
