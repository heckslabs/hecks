//! The resident staff engineer relays a question to Miette and her answer back, each session
//! played from its tape, and when Miette is not reached the supervisor tells it so. The test plays
//! the Harness bluebook's part, routing each `sent` tell to a `deliver` op; the bluebook's
//! recording of the relay is proven by the Ruby spec over the same tapes.

// The helpers below fail the test that calls them, so they expect as a test does.
#![allow(clippy::expect_used)]

mod common;

use common::{count, Served};
use hecks_harness::json::Value;

const STAFF_ENGINEER_BRIEF: &str = "You are the staff engineer role. Relay through send_message.";

/// Each `sent` tell as (sender, addressee, about).
fn sends(seen: &[Value]) -> Vec<(String, String, String)> {
    seen.iter()
        .filter(|tell| tell.str_at("tell") == Some("sent"))
        .map(|tell| {
            let field = |name: &str| tell.str_at(name).unwrap_or_default().to_string();
            (field("session"), field("to"), field("about"))
        })
        .collect()
}

fn text_of(seen: &[Value], message: &str) -> String {
    seen.iter()
        .find(|tell| tell.str_at("tell") == Some("sent") && tell.str_at("message") == Some(message))
        .and_then(|tell| tell.str_at("text"))
        .unwrap_or_default()
        .to_string()
}

fn relayed() -> Vec<Value> {
    let mut served = Served::start();
    served.next();
    served.open(
        "staff-engineer",
        "staff_engineer.jsonl",
        STAFF_ENGINEER_BRIEF,
    );
    served.open("miette", "miette.jsonl", "You are Miette.");
    served.open(
        "coder",
        "coder_asks.jsonl",
        "You are the coder. Ask the staff engineer.",
    );
    let seen = served.route_until(|seen| {
        count(seen, "turn_ended", "staff-engineer") == 3 && count(seen, "turn_ended", "coder") == 2
    });
    served.quit();
    seen
}

fn alone() -> Vec<Value> {
    let mut served = Served::start();
    served.next();
    served.open(
        "staff-engineer",
        "staff_engineer_alone.jsonl",
        STAFF_ENGINEER_BRIEF,
    );
    served.open(
        "reviewer",
        "reviewer_asks.jsonl",
        "You are the reviewer. Ask the staff engineer.",
    );
    let seen = served.route_until(|seen| {
        count(seen, "turn_ended", "staff-engineer") == 3
            && count(seen, "turn_ended", "reviewer") == 2
    });
    served.quit();
    seen
}

#[test]
fn the_staff_engineer_asks_miette_and_relays_her_answer_about_the_question() {
    let seen = relayed();
    let about =
        |sender: &str, to: &str| (sender.to_string(), to.to_string(), "coder-1".to_string());
    assert_eq!(
        sends(&seen),
        [
            (
                "coder".to_string(),
                "staff-engineer".to_string(),
                String::new()
            ),
            about("staff-engineer", "miette"),
            about("miette", "staff-engineer"),
            about("staff-engineer", "coder"),
        ],
        "{seen:#?}"
    );
}

#[test]
fn her_words_reach_the_asker_unchanged() {
    let seen = relayed();
    assert_eq!(
        text_of(&seen, "staff-engineer-2"),
        text_of(&seen, "miette-1")
    );
}

#[test]
fn a_relayed_delivery_names_what_it_is_about() {
    let seen = relayed();
    let delivered = seen
        .iter()
        .find(|tell| {
            tell.str_at("tell") == Some("delivered") && tell.str_at("message") == Some("miette-1")
        })
        .and_then(|tell| tell.str_at("about"));
    assert_eq!(delivered, Some("coder-1"));
}

#[test]
fn when_miette_is_not_reached_the_staff_engineer_is_told_and_tells_the_asker() {
    let seen = alone();
    let refused = seen.iter().any(|tell| {
        tell.str_at("tell") == Some("refused") && tell.str_at("message") == Some("staff-engineer-1")
    });
    let noticed = count(&seen, "noticed", "staff-engineer");
    assert_eq!(
        (refused, noticed, sends(&seen).last().cloned()),
        (
            true,
            1,
            Some((
                "staff-engineer".to_string(),
                "reviewer".to_string(),
                "reviewer-1".to_string()
            ))
        ),
        "{seen:#?}"
    );
}

#[test]
fn a_session_cannot_take_the_harnesss_own_name() {
    let mut served = Served::start();
    served.next();
    served.open("harness", "coder.jsonl", "You are the coder.");
    let refused = served.next();
    assert_eq!(refused.str_at("tell"), Some("refused"));
}
