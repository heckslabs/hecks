//! An urgent message cuts into its addressee's turn: a worker mid-turn is interrupted for the
//! lead's urgent message and takes it next, while a peer's ordinary message waits behind it. Each
//! child is played from its tape, and the test routes each `sent` tell as the bluebook's policy does.

// The helpers below fail the test that calls them, so they expect as a test does.
#![allow(clippy::expect_used)]

mod common;

use common::{count, Served};
use hecks_harness::json::Value;

fn interrupted() -> Vec<Value> {
    let mut served = Served::start();
    assert_eq!(served.next().str_at("tell"), Some("ready"));
    served.open(
        "worker",
        "urgent_worker.jsonl",
        "You are the worker. Carry the change through.",
    );
    served.open(
        "peer",
        "urgent_peer.jsonl",
        "You are the peer. Leave the worker a note.",
    );
    served.open(
        "lead",
        "urgent_lead.jsonl",
        "You are the lead. Main just moved.",
    );
    let seen = served.route_until(|seen| {
        count(seen, "turn_ended", "worker") == 3
            && count(seen, "turn_ended", "lead") == 1
            && count(seen, "turn_ended", "peer") == 1
    });
    served.quit();
    seen
}

fn first(seen: &[Value], kind: &str, message: &str) -> Option<usize> {
    seen.iter().position(|tell| {
        tell.str_at("tell") == Some(kind) && tell.str_at("message") == Some(message)
    })
}

#[test]
fn an_urgent_message_interrupts_the_turn_and_is_its_next() {
    let seen = interrupted();
    let cut = seen.iter().position(|tell| {
        tell.str_at("tell") == Some("turn_ended")
            && tell.str_at("session") == Some("worker")
            && tell.get("is_error").and_then(Value::as_bool) == Some(true)
    });
    assert!(
        first(&seen, "interrupted", "lead-1") < cut && cut < first(&seen, "delivered", "lead-1"),
        "{seen:#?}"
    );
}

#[test]
fn the_urgent_message_is_told_urgent_from_sent_to_delivered() {
    let seen = interrupted();
    let urgent = |kind: &str| {
        first(&seen, kind, "lead-1")
            .and_then(|at| seen[at].get("urgent"))
            .and_then(Value::as_bool)
    };
    assert_eq!(
        [urgent("sent"), urgent("queued"), urgent("delivered")],
        [Some(true); 3]
    );
}

#[test]
fn an_ordinary_message_waits_behind_the_urgent_one_and_interrupts_nothing() {
    let seen = interrupted();
    assert!(
        first(&seen, "queued", "peer-1") < first(&seen, "queued", "lead-1")
            && first(&seen, "delivered", "lead-1") < first(&seen, "delivered", "peer-1")
            && first(&seen, "interrupted", "peer-1").is_none(),
        "{seen:#?}"
    );
    assert_eq!(count(&seen, "interrupted", "worker"), 1);
}
