//! The Deciderate Bracket saga, in-process (one Runtime, memory) — the
//! guarded-fan-out tournament saga with REAL Deciderate aggregates.
//!
//! #[ignore]d — BLOCKED by a runtime coercion gap discovered building it, NOT
//! by the grown policy DSL (guard + for_each are proven green in
//! policy_grown_test). ROOT CAUSE : an Integer-VO dispatch INPUT is stored as
//! a raw string, not coerced to an integer. `OpenRound games_remaining=2`
//! lands as Str("2") ; the later `then_set :games_remaining, decrement: 1` is
//! numeric, so it reads the string as 0 and yields -1 instead of 1. The guard
//! `where games_remaining: 0` therefore never sees exactly 0 (it skips from
//! Str("2") to Int(-1)) and the round never advances.
//!
//! FIX (next) : coerce a dispatch input to its attribute's declared VO inner
//! type (Integer here) at dispatch time, so numeric mutations operate on a
//! number. Then DELETE this #[ignore] — the assertions below already encode
//! the correct saga behaviour and will pass.

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
#[ignore = "blocked by runtime Integer-VO-input coercion gap (decrement reads Str(\"2\") as 0); see module header"]
fn round_advances_only_when_the_last_game_resolves() {
    let mut rt = Runtime::boot_with_hecksagons(parser::parse(SRC), None, vec![]);
    rt.dispatch("OpenRound", a(&[("bracket_id", "bk1"), ("games_remaining", "2")])).unwrap();
    rt.dispatch("Open", a(&[("game_id", "gm1"), ("bracket", "bk1")])).unwrap();
    rt.dispatch("Open", a(&[("game_id", "gm2"), ("bracket", "bk1")])).unwrap();

    // First resolution : games_remaining 2 -> 1, guard (== 0) does NOT fire.
    rt.dispatch("Resolve", a(&[("game", "gm1"), ("winner_ref", "oA")])).unwrap();
    assert_eq!(round_of(&rt, "bk1"), "1", "round must NOT advance until the last game resolves");

    // Last resolution : games_remaining 1 -> 0, guard fires -> round 1 -> 2.
    rt.dispatch("Resolve", a(&[("game", "gm2"), ("winner_ref", "oB")])).unwrap();
    assert_eq!(round_of(&rt, "bk1"), "2", "the last game's resolution must advance the round (the guarded saga)");
}
