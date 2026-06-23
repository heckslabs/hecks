//! Deciderate estimation strategy, in-process (one Runtime, memory) — proves the
//! SECOND convergence strategy : where a preference Decision narrows through a
//! tournament of Games, an ESTIMATION Decision converges by the MEDIAN of its
//! Players' numeric Submissions. This is the 0a `median` reduction composing
//! with a `where` filter (median over a per-decision slice), driven end-to-end
//! through Register -> Make -> Consensus on a booted runtime.
//!
//! It also pins a VERIFIED structural fact : the cross-aggregate ref a `where`
//! filters on must be a STORED VO attribute (`decision, DecisionRef`), NOT a
//! `reference_to` — `reference_to` sets a repo-relationship key that `where`
//! cannot see (proven : a reference_to-only Submission returns median null).
//! This is the same "refs must be stored VOs" lesson the Bracket saga taught
//! for events, now confirmed for queries.

use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), s(v))).collect()
}
fn qv(p: &[(&str, &str)]) -> HashMap<String, String> {
    p.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

const SRC: &str = r#"Hecks.bluebook "Deciderate" do
  core
  aggregate "Decision" do
    identified_by :decision_id
    attribute :decision_id, DecisionId
    value_object "DecisionId" do
      attribute :value, String
    end
    command "Pose" do
      attribute :decision_id, DecisionId
    end
  end
  aggregate "Player" do
    identified_by :player_id
    attribute :player_id, PlayerId
    attribute :handle, Handle
    value_object "PlayerId" do
      attribute :value, String
    end
    value_object "Handle" do
      attribute :value, String
    end
    command "Register" do
      attribute :player_id, PlayerId
      attribute :handle, Handle
    end
  end
  aggregate "Submission" do
    identified_by :submission_id
    attribute :submission_id, SubmissionId
    attribute :decision, DecisionRef
    attribute :player, PlayerRef
    attribute :estimate, Estimate
    value_object "SubmissionId" do
      attribute :value, String
    end
    value_object "DecisionRef" do
      attribute :value, String
    end
    value_object "PlayerRef" do
      attribute :value, String
    end
    value_object "Estimate" do
      attribute :value, Integer
    end
    command "Make" do
      attribute :submission_id, SubmissionId
      attribute :decision, DecisionRef
      attribute :player, PlayerRef
      attribute :estimate, Estimate
    end
    query "Consensus" do |decision|
      where decision: :decision
      median :estimate
    end
    query "ForDecision" do |decision|
      where decision: :decision
    end
  end
end"#;

fn booted() -> Runtime {
    let mut rt = Runtime::boot_with_hecksagons(parser::parse(SRC), None, vec![]);
    rt.dispatch("Pose", a(&[("decision_id", "d1")])).unwrap();
    rt.dispatch("Pose", a(&[("decision_id", "d2")])).unwrap();
    for (id, handle) in [("p1", "ana"), ("p2", "ben"), ("p3", "cy")] {
        rt.dispatch("Register", a(&[("player_id", id), ("handle", handle)])).unwrap();
    }
    // d1 estimates : 10, 30, 50 -> median 30. d2 estimates : 100, 200 -> median 150.
    let subs = [
        ("s1", "d1", "p1", "10"),
        ("s2", "d1", "p2", "30"),
        ("s3", "d1", "p3", "50"),
        ("s4", "d2", "p1", "100"),
        ("s5", "d2", "p2", "200"),
    ];
    for (sid, decision, player, estimate) in subs {
        rt.dispatch(
            "Make",
            a(&[("submission_id", sid), ("decision", decision), ("player", player), ("estimate", estimate)]),
        )
        .unwrap();
    }
    rt
}

#[test]
fn consensus_is_the_median_estimate_per_decision() {
    let rt = booted();
    let d1 = rt.resolve_query("Consensus", &qv(&[("decision", "d1")]));
    assert_eq!(d1["state"]["median"], serde_json::json!(30), "d1 median of [10,30,50] = 30 ; got {}", d1["state"]);
    let d2 = rt.resolve_query("Consensus", &qv(&[("decision", "d2")]));
    assert_eq!(d2["state"]["median"], serde_json::json!(150), "d2 median of [100,200] = 150 ; got {}", d2["state"]);
}

#[test]
fn for_decision_scopes_submissions_to_the_decision() {
    let rt = booted();
    let d1 = rt.resolve_query("ForDecision", &qv(&[("decision", "d1")]));
    // A multi-row plain query returns `state` AS the records array directly.
    let records = d1["state"].as_array().expect("records array");
    assert_eq!(records.len(), 3, "d1 has exactly 3 submissions ; got {}", d1["state"]);
}
