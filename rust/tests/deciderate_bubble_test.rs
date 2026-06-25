//! Deciderate BUBBLE mode — continuous instant-runoff decay, in-process (one
//! Runtime, memory). Proves the THIRD saga shape : a clock tick fans out a
//! Decay over every FLOATING bubble (the 0b for_each), and a bubble that
//! decays to 0 STARVES and pops via a where-GUARD — the same guarded-saga
//! shape as the Bracket's round-advance, only the trigger is a CLOCK
//! (BubbleClock.Tick) instead of a game resolution.
//!
//! The periodic firing is the out-of-process Driver (deciderate.hecksagon
//! `driving on interval`) ; here we dispatch Tick directly — exactly what the
//! clock does — so the for_each + guarded-pop cascade runs in ONE booted
//! runtime. It also pins that a for_each SWEEP resolves the triggered
//! command's `reference_to Bubble` via the swept record's `id` (why Bubble is
//! identified_by :id). The bluebook is a fixture so the test carries no
//! escaped raw-string.

use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

const SRC: &str = include_str!("fixtures/deciderate_bubble.bluebook");

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), s(v))).collect()
}
fn field(rt: &Runtime, agg: &str, id: &str, f: &str) -> String {
    rt.find(agg, id).and_then(|st| st.fields.get(f).map(|v| v.to_string())).unwrap_or_default()
}

#[test]
fn clock_tick_decays_floating_bubbles_and_pops_the_starved_one() {
    let mut rt = Runtime::boot_with_hecksagons(parser::parse(SRC), None, vec![]);
    // Three bubbles for one decision, sizes 1 / 2 / 3.
    for (id, size) in [("b1", "1"), ("b2", "2"), ("b3", "3")] {
        rt.dispatch(
            "Launch",
            a(&[("id", id), ("decision", "d1"), ("option", id), ("size", size)]),
        )
        .unwrap();
    }

    // Tick 1 : the for_each decays every floating bubble 1/2/3 -> 0/1/2 ; b1
    // starves (size 0) and the guard pops it.
    rt.dispatch("Tick", a(&[("clock_id", "clock"), ("last_ticked_at", "t1")])).unwrap();
    assert_eq!(field(&rt, "Bubble", "b1", "status"), "popped", "b1 starved -> popped");
    assert_eq!(field(&rt, "Bubble", "b2", "size"), "1", "b2 decayed 2 -> 1");
    assert_eq!(field(&rt, "Bubble", "b3", "size"), "2", "b3 decayed 3 -> 2");
    assert_eq!(field(&rt, "Bubble", "b2", "status"), "floating", "b2 still floating");

    // Tick 2 : only b2,b3 are floating (b1 popped, excluded from the sweep) ->
    // 1/2 -> 0/1 ; b2 starves and pops, b3 -> 1.
    rt.dispatch("Tick", a(&[("clock_id", "clock"), ("last_ticked_at", "t2")])).unwrap();
    assert_eq!(field(&rt, "Bubble", "b2", "status"), "popped", "b2 starved -> popped");
    assert_eq!(field(&rt, "Bubble", "b3", "size"), "1", "b3 decayed 2 -> 1");
    assert_eq!(field(&rt, "Bubble", "b1", "status"), "popped", "b1 stays popped");
    assert_eq!(field(&rt, "Bubble", "b3", "status"), "floating", "b3 survives");

    // The clock recorded its last beat (the singleton heartbeat persisted).
    assert_eq!(field(&rt, "BubbleClock", "clock", "last_ticked_at"), "t2");
}

#[test]
fn bubbleclock_driver_parses_an_interval_handler() {
    // The DRIVING-SIDE wiring : `driving on interval` is the Schedule kind the
    // Rust drive_scheduler fires (the inverse of the Ruby side's cron). Pin that
    // the BubbleClock adapter parses one interval handler dispatching
    // BubbleClock.Tick — the clock the in-process saga above simulates by hand.
    use storehouse::hecksagon_parser;
    let hex = hecksagon_parser::parse(include_str!("fixtures/deciderate_bubble.hecksagon"));
    let da = hex.driving_adapters.iter().find(|d| d.name == "BubbleClock")
        .expect("BubbleClock driving adapter parsed");
    let h = da.handlers.first().expect("one driving handler on BubbleClock");
    assert_eq!(h.kind, "interval", "the Rust drive_scheduler fires the interval kind");
    assert_eq!(h.arg, "30s");
    assert_eq!(
        h.dispatches.first().map(|d| d.command.as_str()),
        Some("Deciderate::BubbleClock.Tick"),
        "the interval handler fires BubbleClock.Tick",
    );
}
