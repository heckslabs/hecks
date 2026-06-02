//! Sprint-14 retire-sync-cascade-pipeline : the per-aggregate `delivery :actor`
//! vs `delivery :sync` fork retired ; every event flows through
//! `event_bus.publish` from `command_dispatch.rs`. What remains are the
//! mailbox-registry wiring tests that drive `Runtime::enqueue_and_drain`
//! directly — they pin the per-mailbox FIFO + cross-aggregate parallelism
//! preconditions the actor-per-aggregate-instance + async-event-delivery-bus
//! stories will lift into dispatch. The old `delivery_modes_coexist_in_one_runtime`
//! test (which asserted the dispatch-time Sync/Actor fork) retired with the
//! pipeline.

use storehouse::parser;
use storehouse::runtime::{Event, Runtime};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

fn fixture_source() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/migration_coexistence.bluebook");
    fs::read_to_string(&path).expect("fixture readable")
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
