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
use storehouse::runtime::{Runtime, Value};
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
