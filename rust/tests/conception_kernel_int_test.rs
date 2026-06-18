//! conception_kernel planner tests — the integer kinds (slice 2).
//!
//! GreaterThan / GreaterOrEqual / LessThan. The hard slice: their `satisfy` is
//! a compound disjunction (tested directly as a `Satisfy` tree in
//! produced_state.rs's unit tests); here we gate producer-seek, the increment
//! fallback, and `LessThan`'s default-hold against generate_behaviors (the
//! byte-oracle).
//!
//! Each int fixture has a distinct create command so the bootstrap create never
//! collides with the precondition producer's setup count.

mod common;
use common::{assert_empty_chain_but_emits, assert_matches_oracle};

const COUNTER: &str = r#"Hecks.bluebook "Counter" do
  aggregate "Counter" do
    attribute :level, Integer
    command "CreateCounter" do
      reference_to(Counter)
      emits "CounterCreated"
    end
    command "SetLevel" do
      reference_to(Counter)
      attribute :amount, Integer
      emits "LevelSet"
      then_set :level, to: 5
    end
    command "ActivateGte" do
      reference_to(Counter)
      given("at least 3") { level >= 3 }
      emits "ActivatedGte"
    end
    command "ActivateGt" do
      reference_to(Counter)
      given("above 4") { level > 4 }
      emits "ActivatedGt"
    end
    command "ActivateLt" do
      reference_to(Counter)
      given("below 10") { level < 10 }
      emits "ActivatedLt"
    end
  end
end
"#;

#[test]
fn greater_or_equal_set_producer() {
    // level >= 3, SetLevel lands level at 5 (5 >= 3).
    assert_matches_oracle(COUNTER, "Counter", "ActivateGte", &["SetLevel"]);
}

#[test]
fn greater_than_set_producer() {
    // level > 4 → producer must land level at >= 5; SetLevel sets 5.
    assert_matches_oracle(COUNTER, "Counter", "ActivateGt", &["SetLevel"]);
}

#[test]
fn less_than_default_held() {
    // level < 10 holds by default: an Integer defaults to 0, and 0 < 10.
    assert_empty_chain_but_emits(COUNTER, "Counter", "ActivateLt");
}

const LOYALTY: &str = r#"Hecks.bluebook "Loyalty" do
  aggregate "Account" do
    attribute :points, Integer
    command "CreateAccount" do
      reference_to(Account)
      emits "AccountOpened"
    end
    command "Earn" do
      reference_to(Account)
      attribute :amount, Integer
      emits "PointsEarned"
      then_set :points, increment: :amount
    end
    command "Redeem" do
      reference_to(Account)
      given("must have points") { points > 0 }
      emits "Redeemed"
    end
  end
end
"#;

#[test]
fn greater_than_zero_via_increment_fallback() {
    // points > 0 → target 1; no Set lands it, but Earn increments points, and
    // the increment fallback (target <= 1) selects it.
    assert_matches_oracle(LOYALTY, "Account", "Redeem", &["Earn"]);
}
