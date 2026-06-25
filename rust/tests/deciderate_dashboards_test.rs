//! Deciderate role-scoped DASHBOARDS + leaderboards, in-process (one Runtime,
//! memory). Proves the 0a aggregation suite drives real product views :
//!   * Submission.Mine     — scope_to :player row-authZ : a Player sees only
//!     their own submissions (the reserved `actor` kwarg the ACL/edge supplies).
//!   * Submission.PerPlayer — group_by :player : the player leaderboard tally.
//!   * Bubble.Standings     — where + order_by :size, :desc : the live bubble
//!     leaderboard, biggest vote-mass first.
//!   * Game.WinsByOption    — where + group_by :winner_ref : the preference
//!     tournament standings (wins per option).

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

const SRC: &str = include_str!("fixtures/deciderate_dashboards.bluebook");

fn booted() -> Runtime {
    let mut rt = Runtime::boot_with_hecksagons(parser::parse(SRC), None, vec![]);
    // Submissions : p1 makes 3, p2 makes 2 (all decision d1).
    let subs = [
        ("s1", "p1"), ("s2", "p1"), ("s3", "p1"), ("s4", "p2"), ("s5", "p2"),
    ];
    for (id, player) in subs {
        rt.dispatch("Make", a(&[("id", id), ("decision", "d1"), ("player", player), ("estimate", "10")])).unwrap();
    }
    // Bubbles for d1 : sizes 9 / 5 / 2 (single digits so string-order == numeric).
    for (id, size) in [("bA", "9"), ("bB", "5"), ("bC", "2")] {
        rt.dispatch("Launch", a(&[("id", id), ("decision", "d1"), ("size", size)])).unwrap();
    }
    // Resolved games in bracket b1 : oA wins twice, oB once.
    for (id, winner) in [("g1", "oA"), ("g2", "oA"), ("g3", "oB")] {
        rt.dispatch("Record", a(&[("id", id), ("bracket", "b1"), ("winner_ref", winner)])).unwrap();
    }
    rt
}

#[test]
fn mine_scopes_submissions_to_the_actor() {
    let rt = booted();
    let p1 = rt.resolve_query("Mine", &qv(&[("actor", "p1")]));
    assert_eq!(p1["state"]["count"], serde_json::json!(3), "p1 sees 3 ; got {}", p1["state"]);
    let p2 = rt.resolve_query("Mine", &qv(&[("actor", "p2")]));
    assert_eq!(p2["state"]["count"], serde_json::json!(2), "p2 sees 2 ; got {}", p2["state"]);
}

#[test]
fn per_player_tallies_the_leaderboard() {
    let rt = booted();
    let r = rt.resolve_query("PerPlayer", &HashMap::new());
    assert_eq!(r["state"]["groups"]["p1"], serde_json::json!(3), "got {}", r["state"]);
    assert_eq!(r["state"]["groups"]["p2"], serde_json::json!(2), "got {}", r["state"]);
}

#[test]
fn standings_orders_floating_bubbles_by_size_desc() {
    let rt = booted();
    let r = rt.resolve_query("Standings", &qv(&[("decision", "d1")]));
    let arr = r["state"].as_array().expect("records array");
    assert_eq!(arr.len(), 3, "three floating bubbles");
    let ids: Vec<&str> = arr.iter().map(|b| b["id"].as_str().unwrap_or("")).collect();
    assert_eq!(ids, vec!["bA", "bB", "bC"], "biggest vote-mass first ; got {:?}", ids);
}

#[test]
fn wins_by_option_tallies_the_tournament_standings() {
    let rt = booted();
    let r = rt.resolve_query("WinsByOption", &qv(&[("bracket", "b1")]));
    assert_eq!(r["state"]["groups"]["oA"], serde_json::json!(2), "oA won 2 ; got {}", r["state"]);
    assert_eq!(r["state"]["groups"]["oB"], serde_json::json!(1), "oB won 1 ; got {}", r["state"]);
}
