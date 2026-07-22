//! DERIVABILITY AS A STANDING INVARIANT — the verification driver.
//!
//! `verify-projection` proves the claim the whole substrate rests on : current
//! state is DERIVABLE from the Log, so the Log is the source of truth and not a
//! parallel record. Proven once, by an operator running a command, that is an
//! anecdote. A property that must hold CONTINUOUSLY has to be measured
//! continuously — so the verdict becomes queryable domain state
//! (`Verification.Drifted`) instead of console output nobody is watching.
//!
//! The trigger is `Verification.Verify`, fired by the ProjectionVerification
//! Driver on an interval (or by hand, as here). The runtime hook folds the
//! complete Log, compares, re-measures to strip transient races, and dispatches
//! `Verification.Record`.

mod realm_fixture;

use std::collections::HashMap;
use storehouse::runtime::{Runtime, Value};

const TALLY: &str = r#"Hecks.bluebook "Tally" do
  core
  aggregate "Counter" do
    identified_by :name
    attribute :name, Name
    attribute :hits, Hits, default: "0"
    value_object "Name" do
      attribute :value, String
    end
    value_object "Hits" do
      attribute :value, String
    end
    command "Bump" do
      role "System"
      attribute :name, Name
      attribute :hits, Hits
      then_set :hits, to: :hits
      emits "Bumped"
    end
  end
end
"#;

const TALLY_HEX: &str = r#"Hecks.hecksagon "Tally" do
  Tally::Counter.persisted_by("Heki")
  Tally::Counter.event_sourced
end
"#;

fn bump(rt: &mut Runtime, name: &str, hits: &str) {
    let mut attrs = HashMap::new();
    attrs.insert("name".to_string(), Value::Str(name.to_string()));
    attrs.insert("hits".to_string(), Value::Str(hits.to_string()));
    rt.dispatch("Tally::Counter.Bump", attrs).expect("Bump dispatches");
}

/// Fire the trigger the Driver fires.
fn verify(rt: &mut Runtime) {
    let mut attrs = HashMap::new();
    attrs.insert("verification_id".to_string(), Value::Str("projection".to_string()));
    let _ = rt.dispatch("EventSourcing::Verification.Verify", attrs);
}

fn verdict(rt: &mut Runtime, field: &str) -> String {
    match rt.framework_mut().find("Verification", "projection").map(|s| s.get(field).clone()) {
        Some(Value::Str(v)) => v,
        Some(Value::Map(m)) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        Some(other) => other.to_string(),
        None => String::new(),
    }
}

#[test]
fn a_healthy_log_records_a_derivable_verdict() {
    let (mut rt, root) = realm_fixture::boot_realm("es_verify_ok", "tally", TALLY, TALLY_HEX);
    bump(&mut rt, "c1", "1");
    bump(&mut rt, "c1", "2");
    bump(&mut rt, "c2", "5");

    // Nothing has asked yet, so there is no standing verdict.
    assert_eq!(verdict(&mut rt, "status"), "", "precondition : no verdict before the trigger fires");

    verify(&mut rt);

    assert_eq!(
        verdict(&mut rt, "status"),
        "derivable",
        "fold(Log) reconstructs the store, so the standing verdict is derivable",
    );
    assert_eq!(verdict(&mut rt, "drift_fields"), "0", "a healthy log drifts on no fields");
    assert_ne!(verdict(&mut rt, "checked_at"), "", "the verdict is stamped with when it was taken");
    assert_ne!(
        verdict(&mut rt, "fields_checked"),
        "0",
        "it must actually have compared fields — a vacuous pass is not a pass",
    );

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_store_that_disagrees_with_the_log_is_caught_and_named() {
    let (mut rt, root) = realm_fixture::boot_realm("es_verify_drift", "tally", TALLY, TALLY_HEX);
    bump(&mut rt, "c1", "1");
    verify(&mut rt);
    assert_eq!(verdict(&mut rt, "status"), "derivable", "precondition : derivable before tampering");

    // An UNLOGGED WRITE — the exact failure this invariant exists to catch. The
    // store now says something the Log never recorded, so state is no longer
    // derivable from the Log and the substrate's central claim is false.
    let mut tampered = rt.find("Counter", "c1").expect("c1 present").clone();
    tampered.set("hits", Value::Str("31337".to_string()));
    let key = storehouse::runtime::repo_key(None, "Counter");
    let key = if rt.repositories.contains_key(&key) {
        key
    } else {
        storehouse::runtime::repo_key(Some("Tally"), "Counter")
    };
    rt.repositories.get_mut(&key).expect("Counter repo").seed_record(tampered);

    verify(&mut rt);

    assert_eq!(
        verdict(&mut rt, "status"),
        "drifted",
        "an unlogged write must flip the standing verdict to drifted",
    );
    assert_ne!(verdict(&mut rt, "drift_fields"), "0", "the drifting field count must be non-zero");
    let detail = verdict(&mut rt, "detail");
    assert!(
        detail.contains("Counter") && detail.contains("hits"),
        "the verdict must NAME what drifted so it is actionable without re-running by hand — got {detail:?}",
    );

    let _ = std::fs::remove_dir_all(&root);
}
