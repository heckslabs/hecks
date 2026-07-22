//! SNAPSHOTS (Stage 3) — the cache that makes the read O(tail).
//!
//! `Snapshot` + `ReadForward` already existed, but NOTHING ever captured : every
//! read folded the whole Log from watermark 0 forever. This proves the writer now
//! captures once the Log has grown past a THRESHOLD — not a timer, which is what
//! the bluebook declares twice over ("capture by THRESHOLD (every N events) or
//! ON-DEMAND, not by time").
//!
//! Its own test binary because the threshold is tuned by `HECKS_SNAPSHOT_EVERY`
//! and env is process-global — one test per process keeps that honest.
//!
//! The property that matters is NOT "a snapshot appears". It is that the snapshot
//! CANNOT CHANGE WHAT YOU READ : a snapshot is a cache, never the source of
//! truth, so the same read must return the same answer whether it folded the
//! whole Log or a captured prefix plus a short tail. That is asserted directly by
//! reading the same projection from two realms — one that captured, one that
//! never did.

mod realm_fixture;

use std::collections::HashMap;
use storehouse::runtime::{Runtime, Value};

const COUNTER: &str = r#"Hecks.bluebook "Tally" do
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

const COUNTER_HEX: &str = r#"Hecks.hecksagon "Tally" do
  Tally::Counter.persisted_by("Heki")
  Tally::Counter.event_sourced
end
"#;

fn bump(rt: &mut Runtime, name: &str, hits: i64) {
    let mut attrs = HashMap::new();
    attrs.insert("name".to_string(), Value::Str(name.to_string()));
    attrs.insert("hits".to_string(), Value::Str(hits.to_string()));
    rt.dispatch("Tally::Counter.Bump", attrs).expect("Bump dispatches");
}

/// The projection as of now, as (key, value) pairs — the read under test.
fn read_forward(rt: &Runtime) -> Vec<(String, String)> {
    let mut params = HashMap::new();
    params.insert("projection_name".to_string(), "current_state".to_string());
    rt.resolve_query("ReadForward", &params)
        .get("state")
        .and_then(|s| s.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|r| {
                    Some((
                        r.get("key")?.as_str()?.to_string(),
                        r.get("value")?.as_str().unwrap_or_default().to_string(),
                    ))
                })
                .collect()
        })
        .unwrap_or_default()
}

fn watermark(rt: &mut Runtime) -> i64 {
    match rt.framework_mut().find("Snapshot", "current_state").map(|s| s.get("watermark").clone()) {
        Some(Value::Int(i)) => i,
        Some(Value::Map(m)) => m.get("value").and_then(|v| v.as_int()).unwrap_or(0),
        _ => 0,
    }
}

#[test]
fn the_log_captures_a_snapshot_at_the_threshold_without_changing_the_read() {
    // A realm that NEVER captures — the baseline every read is measured against.
    std::env::set_var("HECKS_SNAPSHOT_EVERY", "0");
    let (mut cold, _cold_root) = realm_fixture::boot_realm("es_snapshot_cold", "tally", COUNTER, COUNTER_HEX);
    for i in 1..=12 {
        bump(&mut cold, "c1", i);
    }
    let cold_rows = read_forward(&cold);
    assert_eq!(watermark(&mut cold), 0, "threshold 0 must never capture");
    assert!(!cold_rows.is_empty(), "the fold-from-zero read must return the counter's state");

    // A realm that captures often. Same commands, same order.
    std::env::set_var("HECKS_SNAPSHOT_EVERY", "2");
    let (mut warm, _warm_root) = realm_fixture::boot_realm("es_snapshot_warm", "tally", COUNTER, COUNTER_HEX);
    for i in 1..=12 {
        bump(&mut warm, "c1", i);
    }

    // (1) It captured, and the watermark actually advanced past zero.
    let wm = watermark(&mut warm);
    assert!(wm > 0, "a snapshot must be captured once the Log grows past the threshold");

    // (2) The cached state is not empty — it holds the folded rows, not a husk.
    let cached = warm.framework_mut().find("Snapshot", "current_state").map(|s| s.get("state").clone());
    match cached {
        Some(Value::List(rows)) => assert!(!rows.is_empty(), "the snapshot must cache the folded rows"),
        other => panic!("snapshot state must be a list of rows, got {other:?}"),
    }

    // (3) THE PROPERTY THAT MATTERS : the cache did not change the answer. Read
    // from the captured realm and the never-captured realm and compare. If capture
    // ever dropped or reordered a row, or the watermark skipped events the tail
    // then failed to re-fold, these diverge.
    assert_eq!(
        read_forward(&warm),
        cold_rows,
        "a snapshot is a CACHE : the read must be identical whether it folded the whole Log or a snapshot plus its tail",
    );

    // (4) And it stays right as the Log moves on past the capture.
    bump(&mut warm, "c1", 99);
    bump(&mut cold, "c1", 99);
    assert_eq!(
        read_forward(&warm),
        read_forward(&cold),
        "events after the watermark must still fold forward onto the cache",
    );

    std::env::remove_var("HECKS_SNAPSHOT_EVERY");
}
