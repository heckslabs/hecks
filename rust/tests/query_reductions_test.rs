//! Query reductions end-to-end (deciderate Layer 0a). Proves the new
//! count / max / min / sum / median scalar folds, group_by tallies, and
//! scope_to(:actor) row-authZ actually EXECUTE against a booted runtime —
//! the runtime proof behind the byte-identity goldens. Memory persistence by
//! default (no hecksagon), isolated runtime so the counts are deterministic.

use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

const SRC: &str = r#"
Hecks.bluebook "Reductions" do
  core
  aggregate "Tally" do
    identified_by :id
    attribute :id, String
    attribute :owner, String
    attribute :bucket, String
    attribute :score, Integer

    command "Record" do
      attribute :id, String
      attribute :owner, String
      attribute :bucket, String
      attribute :score, Integer
    end

    query "TallyCount" do
      count
    end
    query "MaxScore" do
      max :score
    end
    query "MinScore" do
      min :score
    end
    query "SumScore" do
      sum :score
    end
    query "MedianScore" do
      median :score
    end
    query "ByBucket" do
      group_by :bucket
    end
    query "MineCount" do
      scope_to :owner
      count
    end
  end
end
"#;

fn sv(v: &str) -> Value { Value::Str(v.to_string()) }
fn dv(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), sv(v))).collect()
}
fn qv(p: &[(&str, &str)]) -> HashMap<String, String> {
    p.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

fn booted() -> Runtime {
    let domain = parser::parse(SRC);
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![]);
    // r1..r5 : (id, owner, bucket, score) — scores 10,20,30,40,50.
    let rows = [
        ("r1", "alice", "a", "10"),
        ("r2", "alice", "a", "20"),
        ("r3", "bob",   "b", "30"),
        ("r4", "bob",   "b", "40"),
        ("r5", "alice", "b", "50"),
    ];
    for (id, owner, bucket, score) in rows {
        rt.dispatch(
            "Reductions::Tally.Record",
            dv(&[("id", id), ("owner", owner), ("bucket", bucket), ("score", score)]),
        )
        .unwrap();
    }
    rt
}

#[test]
fn count_folds_the_whole_set() {
    let rt = booted();
    let r = rt.resolve_query("TallyCount", &HashMap::new());
    assert_eq!(r["state"]["count"], serde_json::json!(5), "got {}", r["state"]);
}

#[test]
fn max_min_sum_median_fold_the_score_field() {
    let rt = booted();
    assert_eq!(rt.resolve_query("MaxScore", &HashMap::new())["state"]["max"], serde_json::json!(50));
    assert_eq!(rt.resolve_query("MinScore", &HashMap::new())["state"]["min"], serde_json::json!(10));
    assert_eq!(rt.resolve_query("SumScore", &HashMap::new())["state"]["sum"], serde_json::json!(150));
    // [10,20,30,40,50] -> middle is 30.
    assert_eq!(rt.resolve_query("MedianScore", &HashMap::new())["state"]["median"], serde_json::json!(30));
}

#[test]
fn group_by_tallies_per_bucket() {
    let rt = booted();
    let r = rt.resolve_query("ByBucket", &HashMap::new());
    let groups = &r["state"]["groups"];
    assert_eq!(groups["a"], serde_json::json!(2), "got {}", groups);
    assert_eq!(groups["b"], serde_json::json!(3), "got {}", groups);
}

#[test]
fn scope_to_filters_rows_to_the_actor() {
    let rt = booted();
    // alice owns r1, r2, r5 -> 3 ; bob owns r3, r4 -> 2.
    let mine = rt.resolve_query("MineCount", &qv(&[("actor", "alice")]));
    assert_eq!(mine["state"]["count"], serde_json::json!(3), "alice: got {}", mine["state"]);
    let bobs = rt.resolve_query("MineCount", &qv(&[("actor", "bob")]));
    assert_eq!(bobs["state"]["count"], serde_json::json!(2), "bob: got {}", bobs["state"]);
}
