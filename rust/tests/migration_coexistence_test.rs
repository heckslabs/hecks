//! Sprint-14 migration-coexistence : both delivery modes coexist in one runtime.
//!
//! Boots the `migration_coexistence.bluebook` fixture (LegacyAggregate +
//! ActorAggregate, sync + actor respectively) and asserts :
//!
//!   1. Both aggregates' commands dispatch cleanly in the SAME runtime.
//!   2. Both emit their event ; the event bus history records both.
//!   3. `Runtime::mailbox_drained` increments ONLY for the actor-mode
//!      dispatch — the sync-mode dispatch leaves it alone.
//!
//! This is the wiring proof for the per-aggregate `delivery :sync|:actor`
//! fork in `command_dispatch.rs`. Per-actor mailboxes + real async drain
//! are the sibling sprint-14 stories `actor-per-aggregate-instance` and
//! `async-event-delivery-bus` ; this test stays valid when those land
//! because the contract (counter increments when actor mode fires) is
//! the same regardless of what the mailbox does internally.

use storehouse::parser;
use storehouse::runtime::{Event, Runtime, Value};
use storehouse::ir::DeliveryMode;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

fn fixture_source() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/migration_coexistence.bluebook");
    fs::read_to_string(&path).expect("fixture readable")
}

fn attrs(pairs: &[(&str, Value)]) -> HashMap<String, Value> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

#[test]
fn delivery_modes_coexist_in_one_runtime() {
    let domain = parser::parse(&fixture_source());
    let mut rt = Runtime::boot(domain);

    // Per-aggregate IR reads the keyword correctly.
    assert_eq!(rt.delivery_for("LegacyAggregate"), DeliveryMode::Sync);
    assert_eq!(rt.delivery_for("ActorAggregate"),  DeliveryMode::Actor);

    // Sync dispatch first — mailbox counter MUST stay at zero.
    let sync_result = rt.dispatch("Note", attrs(&[
        ("note", Value::Str("sync-1".into())),
    ])).expect("sync dispatch ok");
    // The bluebook has Note on both aggregates ; the dispatcher resolves
    // to the first matching aggregate, which is LegacyAggregate by IR
    // declaration order. Force the actor-mode dispatch through the
    // qualified address.
    assert_eq!(sync_result.aggregate_type, "LegacyAggregate");
    assert_eq!(rt.mailbox_drained, 0,
        "sync-mode dispatch must not touch the mailbox stub");

    // Actor dispatch — qualified `ActorAggregate.Note` so the
    // ambiguity-strict dispatcher picks the actor side.
    let actor_result = rt.dispatch("ActorAggregate.Note", attrs(&[
        ("note", Value::Str("actor-1".into())),
    ])).expect("actor dispatch ok");
    assert_eq!(actor_result.aggregate_type, "ActorAggregate");
    assert_eq!(rt.mailbox_drained, 1,
        "actor-mode dispatch must enqueue exactly once through the stub");

    // Both events landed on the bus — coexistence means observers don't
    // care which path the event took.
    let names: Vec<&str> = rt.event_bus.events().iter().map(|e| e.name.as_str()).collect();
    assert!(names.iter().any(|n| *n == "NoteRecorded"),
        "event bus must see NoteRecorded events from both modes : actual = {:?}", names);
    assert_eq!(names.iter().filter(|n| **n == "NoteRecorded").count(), 2,
        "both modes emit ; bus history should hold exactly 2 NoteRecorded entries : actual = {:?}", names);
}

/// Sprint 14 `wire-mailbox-registry-into-event-bus` — fixture (a)
///
/// Two events for the SAME actor address land in one mailbox and reach
/// the bus in dispatch order. Routes through `enqueue_and_drain` (the
/// runtime API the dispatcher calls for `delivery :actor`) with two
/// hand-constructed events sharing one `(aggregate_type, aggregate_id)`
/// — the registry's lazy-create + reuse contract collapses them onto
/// one mailbox and the FIFO drain preserves order through to
/// `event_bus.publish`.
#[test]
fn two_events_on_same_aggregate_land_in_order_via_mailbox() {
    let domain = parser::parse(&fixture_source());
    let mut rt = Runtime::boot(domain);

    let mk_event = |evt_name: &str| Event {
        name: evt_name.to_string(),
        aggregate_type: "ActorAggregate".to_string(),
        aggregate_id:   "actor-1".to_string(),
        data: HashMap::new(),
    };

    rt.enqueue_and_drain(mk_event("First"));
    rt.enqueue_and_drain(mk_event("Second"));
    rt.enqueue_and_drain(mk_event("Third"));

    assert_eq!(rt.mailbox_drained, 3);
    assert_eq!(rt.mailbox_registry.active_count(), 1,
        "three events to the same (type, id) address must share one mailbox");

    let names: Vec<&str> = rt.event_bus.events().iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, vec!["First", "Second", "Third"],
        "mailbox FIFO must publish events to the bus in dispatch order");
}

/// Sprint 14 `wire-mailbox-registry-into-event-bus` — fixture (b)
///
/// Cross-aggregate non-blocking : two events for two DIFFERENT
/// aggregate addresses end up in two DIFFERENT mailboxes on the
/// runtime's `mailbox_registry`. Two mailboxes is the necessary
/// precondition for parallel drain (one OS thread per mailbox in
/// `drain_all_in_parallel`) ; the actor unit test
/// `actor::tests::parallel_across_aggregates_no_block` already proves
/// the parallel drain itself with a Barrier(2). This test pins the
/// runtime wiring : `Runtime::enqueue_and_drain` must route through
/// `self.mailbox_registry.deliver`, not back through the sync
/// publish path, so distinct addresses produce distinct mailboxes.
#[test]
fn event_on_a_while_slow_handler_on_b_is_not_blocked() {
    let domain = parser::parse(&fixture_source());
    let mut rt = Runtime::boot(domain);

    let event_a = Event {
        name: "X".into(), aggregate_type: "ActorAggregate".into(),
        aggregate_id: "A".into(), data: HashMap::new(),
    };
    let event_b = Event {
        name: "Y".into(), aggregate_type: "ActorAggregate".into(),
        aggregate_id: "B".into(), data: HashMap::new(),
    };

    rt.enqueue_and_drain(event_a);
    rt.enqueue_and_drain(event_b);

    assert_eq!(rt.mailbox_registry.active_count(), 2,
        "two events on distinct (type, id) addresses must produce two mailboxes via the runtime path — \
         the necessary precondition for cross-aggregate non-blocking parallelism");
    assert_eq!(rt.mailbox_drained, 2);

    // Both events reached the bus through their respective mailboxes.
    let names: Vec<&str> = rt.event_bus.events().iter().map(|e| e.name.as_str()).collect();
    assert!(names.contains(&"X") && names.contains(&"Y"),
        "both per-mailbox drains must publish to the bus : actual = {:?}", names);
}
