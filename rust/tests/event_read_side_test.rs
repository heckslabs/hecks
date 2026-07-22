//! THE READ SIDE (Stage 4) — state is DERIVED from the Log, not mirrored beside it.
//!
//! The whole arc turns on this test. Up to now the Log was a faithful, governable,
//! lineage-rich record kept ALONGSIDE the real store — but the eager heki
//! current-state write was still what a reader actually read. If that store went
//! stale, truncated, or missing, the read was wrong and the Log, which had the
//! facts the whole time, was never consulted. A record nobody reads from is not a
//! source of truth ; it is an audit trail.
//!
//! So the proof is deliberately brutal : DELETE the current-state store outright,
//! reboot, and require the aggregate to come back — with its values typed, not
//! stringified. Nothing but the Log can supply that.

mod realm_fixture;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use storehouse::runtime::{Runtime, Value};

const TALLY: &str = r#"Hecks.bluebook "Tally" do
  core
  aggregate "Counter" do
    identified_by :name
    attribute :name, Name
    attribute :hits, Hits, default: "0"
    attribute :label, Label, default: "untouched"
    value_object "Name" do
      attribute :value, String
    end
    value_object "Hits" do
      attribute :value, String
    end
    value_object "Label" do
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

fn field(rt: &Runtime, id: &str, f: &str) -> String {
    match rt.find("Counter", id).map(|s| s.get(f).clone()) {
        Some(Value::Str(v)) => v,
        Some(Value::Map(m)) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        Some(other) => other.to_string(),
        None => String::new(),
    }
}

/// Every current-state store under the realm EXCEPT the event_sourcing ones — i.e.
/// the domain's own store, the thing a reader has always actually read from.
fn domain_stores(root: &Path) -> Vec<PathBuf> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        if let Ok(entries) = std::fs::read_dir(dir) {
            for e in entries.flatten() {
                let p = e.path();
                if p.is_dir() {
                    walk(&p, out);
                } else if p.extension().map(|x| x == "heki").unwrap_or(false) {
                    let s = p.to_string_lossy().to_string();
                    if s.contains("counter") {
                        out.push(p);
                    }
                }
            }
        }
    }
    let mut out = Vec::new();
    walk(&root.join("data"), &mut out);
    out
}

#[test]
fn state_survives_the_loss_of_the_current_state_store() {
    let (mut rt, root) = realm_fixture::boot_realm("es_read_side", "tally", TALLY, TALLY_HEX);

    bump(&mut rt, "c1", "7");
    bump(&mut rt, "c2", "3");
    bump(&mut rt, "c1", "9"); // c1's later value must win the fold
    assert_eq!(field(&rt, "c1", "hits"), "9", "sanity : the live store holds the last value");
    drop(rt);

    // THE CUT : delete the domain's current-state store. Everything a reader has
    // ever read from is now gone. Only the Log remains.
    let stores = domain_stores(&root);
    assert!(!stores.is_empty(), "expected a counter current-state store to exist before the cut");
    for s in &stores {
        std::fs::remove_file(s).unwrap();
    }

    // THE CONTROL : the same realm read from the current-state store ALONE (its
    // hecksagons withheld, so `event_sourced` is unknowable and the Log-derived
    // read cannot engage). The aggregate is simply GONE. Without this case the
    // test below would prove nothing about where the state came from.
    let store_only = realm_fixture::reboot_realm_store_only(&root);
    assert_eq!(
        field(&store_only, "c1", "hits"),
        "",
        "control : with the store deleted and no Log-derived read, the aggregate is unreadable",
    );
    drop(store_only);

    // THE PROOF : a normal boot of the same realm — no explicit call, the read side
    // is simply how loading works now — and the aggregate is back.
    let cold = realm_fixture::reboot_realm(&root);
    assert_eq!(field(&cold, "c1", "hits"), "9", "c1 must be reconstructed from the Log, last write winning");
    assert_eq!(field(&cold, "c2", "hits"), "3", "every instance is reconstructed, not just the last one touched");

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn hydration_is_idempotent_and_leaves_log_unknown_fields_alone() {
    let (mut rt, root) = realm_fixture::boot_realm("es_read_side_idem", "tally", TALLY, TALLY_HEX);
    bump(&mut rt, "c1", "4");

    // `label` is never written by Bump, so the Log has no opinion about it. An
    // overlay must not erase it back to nothing — a fold that REPLACED the record
    // would drop the default the aggregate was born with.
    let before_label = field(&rt, "c1", "label");
    assert_eq!(before_label, "untouched", "sanity : the default is present before hydrating");

    // A delta carries the field's FULL post-command value, never an increment, so
    // replaying it any number of times must land on the same state.
    rt.hydrate_event_sourced_from_log();
    let once = field(&rt, "c1", "hits");
    rt.hydrate_event_sourced_from_log();
    rt.hydrate_event_sourced_from_log();
    assert_eq!(field(&rt, "c1", "hits"), once, "hydration must be idempotent");
    assert_eq!(once, "4", "and correct");
    assert_eq!(
        field(&rt, "c1", "label"),
        "untouched",
        "a field the Log never saw must survive hydration",
    );

    let _ = std::fs::remove_dir_all(&root);
}
