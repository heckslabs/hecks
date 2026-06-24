//! Deciderate AIR-SUPPLY votes, in-process (one Runtime, memory). Proves the
//! bubble vote mechanic Chris specified : Players SUPPLY AIR to a bubble
//! (Cast -> InflateOnVote inflates it) ; the bubble decays ; when it POPS, its
//! votes are VOIDED — the air DISAPPEARS, NOT migrated to a next-best
//! (VoidVotesOnPop fans out Vote.Void over the popped bubble's live votes). A
//! supporter whose bubble popped re-engages by casting on another bubble.

use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), s(v))).collect()
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

#[test]
fn casting_a_vote_supplies_air_and_inflates_the_bubble() {
    let rt = booted();
    assert_eq!(field(&rt, "Bubble", "bA", "size"), "2", "two votes -> two units of air");
}

#[test]
fn popping_voids_the_votes_so_the_air_disappears() {
    let mut rt = booted();
    // Decay bA to 0 : tick twice (2 -> 1 -> 0 -> pop). The pop voids the votes.
    rt.dispatch("Tick", a(&[("clock_id", "clock"), ("last_ticked_at", "t1")])).unwrap();
    rt.dispatch("Tick", a(&[("clock_id", "clock"), ("last_ticked_at", "t2")])).unwrap();
    assert_eq!(field(&rt, "Bubble", "bA", "status"), "popped", "bA starved and popped");
    // The air disappears : both votes are voided, NOT migrated anywhere.
    assert_eq!(field(&rt, "Vote", "v1", "status"), "void", "v1 voided on pop");
    assert_eq!(field(&rt, "Vote", "v2", "status"), "void", "v2 voided on pop");
}
