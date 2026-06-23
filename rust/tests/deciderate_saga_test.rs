//! The Deciderate Bracket saga, in-process (one Runtime, memory) — proves the
//! grown policy DSL composes into the tournament saga with NO new primitive:
//! a Bracket aggregate + a where-GUARDED policy. Each GameResolved decrements
//! the Bracket's games_remaining ; when it reaches 0 the guard fires and the
//! round advances. This is the deciderate vertical slice's payoff — 0a + 0b
//! grammar driving a real tournament saga end-to-end.
//!
//! Two runtime fixes (made while building it, both committed alongside) were
//! required and are exercised here :
//!   1. numeric mutations (increment/decrement) now read the current value
//!      through Int / numeric-Str / single-value-VO-map via current_numeric,
//!      so a counter set from a dispatch input (Str("2")) decrements to 1, not
//!      -1 (it used to match only Value::Int and read everything else as 0) ;
//!   2. an emitted event now carries the command's CHANGED state fields
//!      (deltas), not just its inputs, so a policy can GUARD on the resulting
//!      state (`where games_remaining: 0` after the decrement).

use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), s(v))).collect()
}
fn round_of(rt: &Runtime, bracket: &str) -> String {
    rt.find("Bracket", bracket)
        .and_then(|st| st.fields.get("round").map(|v| v.to_string()))
        .unwrap_or_default()
}

const SRC: &str = r#"Hecks.bluebook "Deciderate" do
  core
  aggregate "Bracket" do
    identified_by :bracket_id
    attribute :bracket_id, BracketId
    attribute :round, RoundNumber, default: 1
    attribute :games_remaining, GamesRemaining, default: 0
    value_object "BracketId" do
      attribute :value, String
    end
    value_object "RoundNumber" do
      attribute :value, Integer
    end
    value_object "GamesRemaining" do
      attribute :value, Integer
    end
    command "OpenRound" do
      attribute :bracket_id, BracketId
      attribute :games_remaining, GamesRemaining
      emits "RoundOpened"
    end
    command "RecordResolution" do
      reference_to Bracket
      then_set :games_remaining, decrement: 1
      emits "ResolutionRecorded"
    end
    command "AdvanceRound" do
      reference_to Bracket
      then_set :round, increment: 1
      emits "RoundAdvanced"
    end
  end
  aggregate "Game" do
    identified_by :game_id
    attribute :game_id, GameId
    attribute :bracket, BracketRef
    attribute :status, GameStatus, default: "pending" do
      transition "Resolve" => "resolved"
    end
    attribute :winner_ref, WinnerRef, default: "none"
    value_object "GameId" do
      attribute :value, String
    end
    value_object "BracketRef" do
      attribute :value, String
    end
    value_object "GameStatus" do
      attribute :value, String
    end
    value_object "WinnerRef" do
      attribute :value, String
    end
    command "Open" do
      attribute :game_id, GameId
      attribute :bracket, BracketRef
    end
    command "Resolve" do
      reference_to Game
      attribute :winner_ref, WinnerRef
      then_set :winner_ref, to: :winner_ref
      emits "GameResolved"
    end
  end
  policy "TallyResolution" do
    on "GameResolved"
    trigger "Bracket.RecordResolution"
  end
  policy "AdvanceRound" do
    on "ResolutionRecorded"
    where games_remaining: 0
    trigger "Bracket.AdvanceRound"
  end
end"#;

#[test]
fn round_advances_only_when_the_last_game_resolves() {
    let mut rt = Runtime::boot_with_hecksagons(parser::parse(SRC), None, vec![]);
    rt.dispatch("OpenRound", a(&[("bracket_id", "bk1"), ("games_remaining", "2")])).unwrap();
    rt.dispatch("Open", a(&[("game_id", "gm1"), ("bracket", "bk1")])).unwrap();
    rt.dispatch("Open", a(&[("game_id", "gm2"), ("bracket", "bk1")])).unwrap();

    // First resolution : games_remaining 2 -> 1 ; guard (== 0) does NOT fire.
    rt.dispatch("Resolve", a(&[("game", "gm1"), ("winner_ref", "oA")])).unwrap();
    assert_eq!(round_of(&rt, "bk1"), "1", "round must NOT advance until the last game resolves");

    // Last resolution : games_remaining 1 -> 0 ; guard fires -> round 1 -> 2.
    rt.dispatch("Resolve", a(&[("game", "gm2"), ("winner_ref", "oB")])).unwrap();
    assert_eq!(round_of(&rt, "bk1"), "2", "the last game's resolution must advance the round (the guarded saga)");
}
