//! conception_kernel planner tests — `Equals` + the list kinds (slice 1).
//!
//! Each test gates the kernel's `plan()` against `generate_behaviors` (the
//! byte-oracle) via `common::assert_matches_oracle`: same chain, same
//! per-producer setup counts. `recursion_no_double_seed` mirrors the oracle's
//! `min_size_list_is_idempotent_across_recursion` — recursion + ProducedState
//! threading without re-seeding the appends.

mod common;
use common::{assert_empty_chain_but_emits, assert_matches_oracle};

const CART: &str = r#"Hecks.bluebook "Cart" do
  aggregate "Cart" do
    attribute :items, String, list: true
    command "OpenCart" do
      emits "CartOpened"
    end
    command "AddItem" do
      reference_to(Cart)
      attribute :name, String
      emits "ItemAdded"
      then_set :items, append: :name
    end
    command "Checkout" do
      reference_to(Cart)
      given("cart must have items") { items.size > 0 }
      emits "CheckedOut"
    end
    command "Bulk" do
      reference_to(Cart)
      given("at least 3") { items.size >= 3 }
      emits "BulkApplied"
    end
    command "Pair" do
      reference_to(Cart)
      given("more than one") { items.size > 1 }
      emits "Paired"
    end
    command "Reset" do
      reference_to(Cart)
      given("must be empty") { items.empty? }
      emits "WasReset"
    end
  end
end
"#;

#[test]
fn non_empty_list_one_append() {
    assert_matches_oracle(CART, "Cart", "Checkout", &["AddItem"]);
}

#[test]
fn min_size_list_three_appends() {
    assert_matches_oracle(CART, "Cart", "Bulk", &["AddItem", "AddItem", "AddItem"]);
}

#[test]
fn size_gt_one_is_two_appends() {
    assert_matches_oracle(CART, "Cart", "Pair", &["AddItem", "AddItem"]);
}

#[test]
fn empty_list_default_held_no_steps() {
    assert_empty_chain_but_emits(CART, "Cart", "Reset");
}

const SWITCH: &str = r#"Hecks.bluebook "Switch" do
  aggregate "Device" do
    attribute :ready, Boolean
    command "Initialize" do
      reference_to(Device)
      emits "Initialized"
      then_set :ready, to: true
    end
    command "Activate" do
      reference_to(Device)
      given("device must be ready") { ready == true }
      emits "Activated"
    end
  end
end
"#;

#[test]
fn equals_set_producer() {
    assert_matches_oracle(SWITCH, "Device", "Activate", &["Initialize"]);
}

const MIXED: &str = r#"Hecks.bluebook "Episode" do
  aggregate "Episode" do
    attribute :segments, String, list: true
    attribute :tags, String, list: true
    command "PlanEpisode" do
      emits "EpisodePlanned"
    end
    command "AddSegment" do
      reference_to(Episode)
      attribute :title, String
      emits "SegmentAdded"
      then_set :segments, append: :title
    end
    command "AddTag" do
      reference_to(Episode)
      attribute :tag, String
      emits "TagAdded"
      then_set :tags, append: :tag
    end
    command "Publish" do
      reference_to(Episode)
      given("enough segments") { segments.size >= 3 }
      given("at least one tag") { tags.size > 0 }
      emits "Published"
    end
  end
end
"#;

#[test]
fn mixed_min_size_and_non_empty_different_fields() {
    assert_matches_oracle(
        MIXED,
        "Episode",
        "Publish",
        &["AddSegment", "AddSegment", "AddSegment", "AddTag"],
    );
}

const RECURSE: &str = r#"Hecks.bluebook "Cart" do
  aggregate "Cart" do
    attribute :items, String, list: true
    attribute :status, String, default: "open"
    command "OpenCart" do
      emits "CartOpened"
    end
    command "AddItem" do
      reference_to(Cart)
      attribute :name, String
      emits "ItemAdded"
      then_set :items, append: :name
    end
    command "Finalize" do
      reference_to(Cart)
      given("must have enough items") { items.size >= 2 }
      emits "Finalized"
      then_set :status, to: "finalized"
    end
    command "Audit" do
      reference_to(Cart)
      given("must have enough items") { items.size >= 2 }
      given("must be finalized") { status == "finalized" }
      emits "Audited"
    end
  end
end
"#;

#[test]
fn recursion_no_double_seed() {
    // Audit needs size>=2 (2 AddItem) AND status==finalized (Finalize, which
    // ITSELF needs size>=2). The recursion must not re-seed the appends.
    assert_matches_oracle(RECURSE, "Cart", "Audit", &["AddItem", "AddItem", "Finalize"]);
}
