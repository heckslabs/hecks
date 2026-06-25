//! Deciderate AIR-SUPPLY votes, in-process (one Runtime, memory). Proves the
//! bubble vote mechanic Chris specified : Players SUPPLY AIR to a bubble
//! (Cast -> InflateOnVote inflates it) ; the bubble decays ; when it POPS, its
//! votes are SETTLED (live -> spent) : the air does NOT transfer to a next-best
//! (no migration), but the inflate is REMEMBERED in stats — the Vote record
//! persists and still counts in the per-player inflate tally. A supporter whose
//! bubble popped re-engages by casting on another bubble.

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
fn field(rt: &Runtime, agg: &str, id: &str, f: &str) -> String {
    rt.find(agg, id).and_then(|st| st.fields.get(f).map(|v| v.to_string())).unwrap_or_default()
}

const SRC: &str = include_str!("fixtures/deciderate_votes.bluebook");

fn booted() -> Runtime {
    let mut rt = Runtime::boot_with_hecksagons(parser::parse(SRC), None, vec![]);
    // A bubble for decision d1, launched empty.
    rt.dispatch("Launch", a(&[("id", "bA"), ("decision", "d1"), ("size", "0")])).unwrap();
    // Two players each supply a unit of air to bA (Cast -> InflateOnVote).
    rt.dispatch("Cast", a(&[("id", "v1"), ("bubble", "bA"), ("player", "p1")])).unwrap();
    rt.dispatch("Cast", a(&[("id", "v2"), ("bubble", "bA"), ("player", "p2")])).unwrap();
    rt
}

fn pop_it(rt: &mut Runtime) {
    // Decay bA to 0 : tick twice (2 -> 1 -> 0 -> pop). The pop settles the votes.
    rt.dispatch("Tick", a(&[("clock_id", "clock"), ("last_ticked_at", "t1")])).unwrap();
    rt.dispatch("Tick", a(&[("clock_id", "clock"), ("last_ticked_at", "t2")])).unwrap();
}

#[test]
fn casting_a_vote_supplies_air_and_inflates_the_bubble() {
    let rt = booted();
    assert_eq!(field(&rt, "Bubble", "bA", "size"), "2", "two votes -> two units of air");
}

#[test]
fn popping_settles_the_votes_air_does_not_transfer() {
    let mut rt = booted();
    pop_it(&mut rt);
    assert_eq!(field(&rt, "Bubble", "bA", "status"), "popped", "bA starved and popped");
    // The air does not transfer : both votes settle to spent (not migrated, not deleted).
    assert_eq!(field(&rt, "Vote", "v1", "status"), "spent", "v1 settled on pop");
    assert_eq!(field(&rt, "Vote", "v2", "status"), "spent", "v2 settled on pop");
}

#[test]
fn inflates_are_remembered_in_stats_after_the_pop() {
    let mut rt = booted();
    pop_it(&mut rt);
    // The bubble is gone, but the inflates are REMEMBERED : the per-player tally
    // still counts each player's spent vote.
    let stats = rt.resolve_query("InflatesByPlayer", &qv(&[]));
    assert_eq!(stats["state"]["groups"]["p1"], serde_json::json!(1), "p1's inflate remembered ; got {}", stats["state"]);
    assert_eq!(stats["state"]["groups"]["p2"], serde_json::json!(1), "p2's inflate remembered ; got {}", stats["state"]);
}
