//! Phase 3 proof — the outbox + pump async seam.
//!
//! A command's core mutation is applied synchronously and touches exactly
//! ONE aggregate. Its policy-cascade reaction is no longer run inline ;
//! it is enqueued on the runtime outbox and delivered by `pump()` as a
//! SEPARATE phase. `dispatch_deferred` returns with the cascade NOT yet
//! run ; `pump()` then delivers it. This is the seam that makes
//! between-aggregate consistency eventual rather than synchronous.
//!
//! The canonical cascade : AcceptParcel emits ParcelAccepted, which the
//! policy SortOnAccept turns into SortParcel (status -> "sorted"). The
//! direct mutation (status -> "accepted") lands in the core dispatch ; the
//! cascade mutation (status -> "sorted") lands only on pump.

use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(p: &[(&str, Value)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

const SOURCE: &str = r#"Hecks.bluebook "Pipeline" do
  aggregate "Parcel" do
    identified_by :ref
    attribute :ref, String
    attribute :status, String
    command "AcceptParcel" do
      attribute :ref, String
      emits "ParcelAccepted"
      then_set :status, to: "accepted"
    end
    command "SortParcel" do
      reference_to(Parcel)
      emits "ParcelSorted"
      then_set :status, to: "sorted"
    end
  end
  policy "SortOnAccept" do
    on "ParcelAccepted"
    trigger "SortParcel"
  end
end
"#;

fn status(rt: &Runtime, id: &str) -> Option<String> {
    rt.all_qualified(Some("Pipeline"), "Parcel")
        .into_iter()
        .find(|r| r.id == id)
        .and_then(|r| r.fields.get("status").map(|v| v.to_string()))
}

#[test]
fn deferred_dispatch_holds_the_cascade_until_pump() {
    let domain = parser::parse(SOURCE);
    let mut rt = Runtime::boot(domain);

    // Deferred : the core mutation (status -> accepted) lands on ONE
    // aggregate, but the policy cascade (SortParcel -> status: sorted) is
    // ENQUEUED, not run. This is the single-aggregate-transaction step.
    rt.dispatch_deferred("Pipeline::Parcel.AcceptParcel", attrs(&[("ref", s("p1"))])).unwrap();
    assert_eq!(status(&rt, "p1").as_deref(), Some("accepted"),
        "core mutation applied synchronously");
    // The reaction has NOT been delivered yet — the async seam.
    assert_ne!(status(&rt, "p1").as_deref(), Some("sorted"),
        "policy cascade is DEFERRED — not run inline with the command");

    // Pump delivers the enqueued reaction as a separate phase.
    rt.pump();
    assert_eq!(status(&rt, "p1").as_deref(), Some("sorted"),
        "policy cascade delivered by pump() — reaction is its own phase");
}

#[test]
fn eager_dispatch_settles_the_cascade_in_one_call() {
    // The default eager path auto-pumps, so every existing caller sees the
    // cascade settled on return — the live body keeps working unchanged.
    let domain = parser::parse(SOURCE);
    let mut rt = Runtime::boot(domain);
    rt.dispatch("Pipeline::Parcel.AcceptParcel", attrs(&[("ref", s("p1"))])).unwrap();
    assert_eq!(status(&rt, "p1").as_deref(), Some("sorted"),
        "eager dispatch auto-pumps — cascade settled, body-safe");
}
