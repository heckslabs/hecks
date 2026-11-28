//! A reviewer and a coder exchange messages through the supervisor, each child played from its
//! tape. The test stands where the Harness bluebook's policy stands in a real run: it hears each
//! `sent` tell and answers with a `deliver` op, so what is proven here is the supervisor and the
//! protocol, and the bluebook's own part is proven by the Ruby spec over the same tapes.

// The helpers below fail the test that calls them, so they expect as a test does.
#![allow(clippy::expect_used)]

mod common;

use common::{count, Served};
use hecks_harness::json::{self, Value};
use hecks_harness::measure;

fn exchanged() -> (Vec<Value>, Vec<Value>, Vec<String>) {
    let mut served = Served::start();
    assert_eq!(served.next().str_at("tell"), Some("ready"));
    served.open(
        "reviewer",
        "reviewer.jsonl",
        "You are the reviewer. Review the coder's change to the ledger.",
    );
    served.open(
        "coder",
        "coder.jsonl",
        "You are the coder. Your change to the ledger is up for review.",
    );
    let seen = served.route_until(|seen| {
        count(seen, "turn_ended", "reviewer") == 2 && count(seen, "turn_ended", "coder") == 3
    });
    let (rest, heard) = served.quit();
    (seen, rest, heard)
}

#[test]
fn a_reviewer_and_a_coder_exchange_three_messages_and_stop_cleanly() {
    let (seen, rest, heard) = exchanged();
    let sent: Vec<(&str, &str)> = seen
        .iter()
        .filter(|tell| tell.str_at("tell") == Some("sent"))
        .map(|tell| {
            (
                tell.str_at("session").unwrap_or_default(),
                tell.str_at("to").unwrap_or_default(),
            )
        })
        .collect();
    assert_eq!(
        sent,
        [
            ("reviewer", "coder"),
            ("coder", "reviewer"),
            ("reviewer", "coder")
        ]
    );
    assert_eq!(
        count(&seen, "started", "reviewer") + count(&seen, "started", "coder"),
        2
    );
    let stopped: Vec<f64> = rest
        .iter()
        .filter(|tell| tell.str_at("tell") == Some("stopped"))
        .filter_map(|tell| tell.get("code").and_then(Value::as_f64))
        .collect();
    assert_eq!(stopped, [0.0, 0.0], "both children exit 0: {heard:#?}");
}

#[test]
fn the_shell_is_withheld_and_the_session_is_told() {
    let (seen, _, _) = exchanged();
    let denied: Vec<&str> = seen
        .iter()
        .filter(|tell| tell.str_at("tell") == Some("denied"))
        .filter_map(|tell| tell.str_at("tool"))
        .collect();
    assert_eq!(denied, ["Bash"]);
}

#[test]
fn a_message_to_a_session_mid_turn_is_held_until_its_turn_ends() {
    let (seen, _, _) = exchanged();
    let position = |kind: &str| {
        seen.iter().position(|tell| {
            tell.str_at("tell") == Some(kind) && tell.str_at("message") == Some("reviewer-1")
        })
    };
    let first_turn = seen.iter().position(|tell| {
        tell.str_at("tell") == Some("turn_ended") && tell.str_at("session") == Some("coder")
    });
    assert!(
        position("queued") < first_turn && first_turn < position("delivered"),
        "{seen:#?}"
    );
}

#[test]
fn the_exchange_is_delivered_within_the_baseline() {
    let (_, _, heard) = exchanged();
    let measured = measure::measure(&heard.join("\n"));
    assert!(
        measured.within_baseline() && measured.delivery.count == 3 && measured.answer.count == 2,
        "{}",
        measured.to_value().to_json()
    );
}

#[test]
fn a_delivery_to_no_open_session_is_refused_by_name() {
    let mut served = Served::start();
    served.next();
    served.op(&json::parse(
        r#"{"op":"deliver","session":"nobody","message":"x-1","from":"x","text":"hi"}"#,
    )
    .expect("an op"));
    let refused = served.next();
    assert_eq!(
        (
            refused.str_at("tell"),
            refused.str_at("message"),
            refused.str_at("reason")
        ),
        (
            Some("refused"),
            Some("x-1"),
            Some("no open session has that name")
        )
    );
}

#[test]
fn a_child_that_leaves_its_tape_exits_with_a_failure() {
    let mut served = Served::start();
    served.next();
    served.open("coder", "coder.jsonl", "Not the brief the tape expects.");
    let stopped = served.route_until(|seen| {
        seen.iter()
            .any(|tell| tell.str_at("tell") == Some("stopped"))
    });
    let code = stopped
        .last()
        .and_then(|tell| tell.get("code"))
        .and_then(Value::as_f64);
    assert_eq!(code, Some(2.0));
}
