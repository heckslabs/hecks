//! End-to-end proof that the `event_sourced` hecksagon directive (persistence+)
//! actually WRITES to the event Log — slice 1 of the outbox-as-event-sourcing
//! arc (inbox/PLAN-outbox-as-projection-not-aggregate.md).
//!
//! Steps 1 + 2 shipped the directive (`aggregate_is_event_sourced` + the
//! parser's no-paren `FQN.verb` form) and marked the framework `OutboundEvent`
//! with it. Both were proven at the UNIT level. Nothing yet proved the whole
//! path : boot a real corpus carrying the real `outbound_event.hecksagon`,
//! dispatch the outbox's own Record -> Claim lifecycle, and see those deltas
//! land as immutable `EventSourcing::Event` records.
//!
//! Two assertions, and the SECOND is what makes the first mean anything :
//!   1. POSITIVE — OutboundEvent (carrying the directive) writes its Record and
//!      Claim deltas to the Log.
//!   2. NEGATIVE CONTROL — a sibling aggregate in the SAME runtime and the SAME
//!      dispatch pass, persisted identically but WITHOUT the directive, writes
//!      nothing. Without this, a stray `HECKS_EVENT_SOURCING=1` in the ambient
//!      environment (the global override, which other tests set) would make the
//!      positive assertion pass for entirely the wrong reason. The control
//!      fails loudly in that case, so the proof cannot be faked.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use storehouse::runtime::{AggregateState, Runtime, Value};
use storehouse::{corpus_loader, embed};

fn conception() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("hecks_conception")
}

/// Copy every plain file from `from` into `to`, creating `to`. Shallow — the
/// framework dirs we assemble are flat leaf dirs.
fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap_or_else(|e| panic!("read {:?}: {}", from, e)) {
        let entry = entry.unwrap();
        if entry.file_type().unwrap().is_file() {
            std::fs::copy(entry.path(), to.join(entry.file_name())).unwrap();
        }
    }
}

/// A sibling domain persisted exactly like the outbox but carrying NO
/// `event_sourced` directive — the negative control.
const CONTROL: &str = r#"Hecks.bluebook "Control" do
  aggregate "Ledger" do
    identified_by :entry_id
    attribute :entry_id, EntryId
    attribute :memo,     Memo
    value_object "EntryId" do
      attribute :value, String
    end
    value_object "Memo" do
      attribute :value, String
    end
    command "Post" do
      role "System"
      attribute :entry_id, EntryId
      attribute :memo,     Memo
      then_set :memo, to: :memo
      emits "Posted"
    end
  end
end
"#;

const CONTROL_HEX: &str = r#"Hecks.hecksagon "Control" do
  Control::Ledger.persisted_by("Heki")
end
"#;

fn s(v: &str) -> Value {
    Value::Str(v.to_string())
}

#[test]
fn event_sourced_outbox_writes_its_lifecycle_deltas_to_the_log() {
    let c = conception();
    let root = std::env::temp_dir().join("es_outbox_log_proof");
    let _ = std::fs::remove_dir_all(&root);

    // The real framework corpus, structure preserved so realm/store paths
    // resolve the way they do in production.
    let fw = root.join("aggregates").join("framework");
    copy_dir(&c.join("aggregates/framework/adapters"), &fw.join("adapters"));
    copy_dir(&c.join("aggregates/framework/families"), &fw.join("families"));
    copy_dir(
        &c.join("aggregates/framework/event_sourcing/bluebook"),
        &fw.join("event_sourcing/bluebook"),
    );
    copy_dir(
        &c.join("aggregates/framework/hexagon/bluebook"),
        &fw.join("hexagon/bluebook"),
    );

    let ctl = fw.join("control/bluebook");
    std::fs::create_dir_all(&ctl).unwrap();
    std::fs::write(ctl.join("control.bluebook"), CONTROL).unwrap();
    std::fs::write(ctl.join("control.hecksagon"), CONTROL_HEX).unwrap();

    let agg_dir = root.join("aggregates");
    let agg_dir = agg_dir.to_str().unwrap();
    let domain = corpus_loader::load_combined_domain(agg_dir);
    let hecksagons = embed::load_hecksagons(agg_dir);
    assert!(
        hecksagons.iter().any(|h| h
            .bindings
            .iter()
            .any(|b| b.verb == "event_sourced" && b.aggregate.ends_with("OutboundEvent"))),
        "the real outbound_event.hecksagon must carry the event_sourced directive \
         (if this fails, step 2 regressed or the parser dropped the no-paren form)",
    );

    let data = root.join("data").to_string_lossy().into_owned();
    let mut rt = Runtime::boot_with_framework_dir(
        domain,
        Some(data),
        hecksagons,
        &root.join("aggregates"),
    );

    // Record -> Claim : the outbox's own lifecycle, dispatched as any host would.
    let mut rec = HashMap::new();
    rec.insert("delivery_id".to_string(), s("order-1::Stripe"));
    rec.insert("adapter".to_string(), s("Stripe"));
    rec.insert("event".to_string(), s("OrderPlaced"));
    rec.insert("source_type".to_string(), s("Shop::Order"));
    rec.insert("source_id".to_string(), s("order-1"));
    rec.insert("payload".to_string(), s("{}"));
    rec.insert("success_command".to_string(), s("Shop::Order.Authorize"));
    rec.insert("failure_command".to_string(), s("Shop::Order.Decline"));
    rt.dispatch("OutboundEvent::OutboundEvent.Record", rec)
        .expect("Record dispatches");

    let mut claim = HashMap::new();
    claim.insert("delivery_id".to_string(), s("order-1::Stripe"));
    rt.dispatch("OutboundEvent::OutboundEvent.Claim", claim)
        .expect("Claim dispatches");

    // The control, in the same pass — same runtime, same persistence, no directive.
    let mut post = HashMap::new();
    post.insert("entry_id".to_string(), s("e-1"));
    post.insert("memo".to_string(), s("not event sourced"));
    rt.dispatch("Control::Ledger.Post", post).expect("Post dispatches");

    let events = rt.all_qualified(Some("EventSourcing"), "Event");
    let agg_of = |e: &AggregateState| e.get("aggregate_name").to_string();
    let outbox: Vec<&AggregateState> = events
        .iter()
        .filter(|e| agg_of(e) == "OutboundEvent")
        .copied()
        .collect();

    assert!(
        !outbox.is_empty(),
        "the event_sourced outbox must write its deltas to the Log \
         (got {} Log events overall)",
        events.len(),
    );

    // The delta VO is {field, value} — the Claim's status transition is the one
    // delta that proves the LIFECYCLE (not just the create) reaches the Log.
    let delta_field = |e: &AggregateState| match e.get("delta") {
        Value::Map(m) => m.get("field").map(|v| v.to_string()).unwrap_or_default(),
        _ => String::new(),
    };
    let delta_value = |e: &AggregateState| match e.get("delta") {
        Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        _ => String::new(),
    };

    assert!(
        outbox.iter().any(|e| delta_field(e) == "adapter" && delta_value(e).contains("Stripe")),
        "Record's deltas reach the Log (looking for adapter=Stripe among {:?})",
        outbox.iter().map(|e| (delta_field(e), delta_value(e))).collect::<Vec<_>>(),
    );
    assert!(
        outbox.iter().any(|e| delta_field(e) == "status" && delta_value(e).contains("claimed")),
        "Claim's status transition reaches the Log — the lifecycle is sourced, \
         not only the create (deltas seen: {:?})",
        outbox.iter().map(|e| (delta_field(e), delta_value(e))).collect::<Vec<_>>(),
    );

    // NEGATIVE CONTROL — the directive is what drives the write, not the global
    // env override. If HECKS_EVENT_SOURCING leaked in, this is what catches it.
    let controls: Vec<&AggregateState> =
        events.iter().filter(|e| agg_of(e) == "Ledger").copied().collect();
    assert!(
        controls.is_empty(),
        "an aggregate WITHOUT event_sourced must write nothing to the Log — \
         got {} Ledger events. If HECKS_EVENT_SOURCING is set in this \
         environment, the positive assertions above prove nothing.",
        controls.len(),
    );

    let _ = std::fs::remove_dir_all(&root);
}
