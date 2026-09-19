require "spec_helper"
require "hecks/fuzzing"

# BUG#145 (QualityControl ledger) — the duplicate-identity guard BUG#13
# added for a single caller-supplied `append:` (`MutationApplier#
# check_entity_collision`, mutation_applier.rb) only ever ran on an
# aggregate-owned entity list (`entity_element`, mutation_applier.rb's own
# call site). It was never mirrored onto an entity-owned nested list
# (`EntityElement#appended_to_element`, entity_element.rb) — the shape
# `qa/stress_domains/nested_pieces` (`Board.AddCard`, appending a `Card`
# onto `Board.cards`, itself nested two levels under `Workspace`) is the
# first corpus member to exercise, per that domain's own NOTES.md ("a
# speculative runtime fix... was drafted, verified not to regress the
# existing suite, and then deliberately reverted: it does
# not resolve BUG#4 ... an unverified runtime change with no failing-test
# demonstration of its own is not something this loop ships"). Found live
# by `bin/qa_sweep nested_pieces`'s first real differential sweep
# (SW-nested_pieces-1789775748, seed 11, shrunk to 4 steps): Ruby silently
# appends a second `Card` under an already-held `sequence`, Rust's
# generated code refuses `AlreadyExists` (`rust/project/mutations.rb`'s
# own `emit_mutation_line_body` runs the identical collision guard
# unconditionally for both an aggregate-owned and an entity-owned append,
# since its own IR walk never splits the two the way Ruby's runtime does)
# — a genuine Ruby/Rust divergence, Ruby being the one with the gap this
# time (BUG#13's own precedent was the other way around).
RSpec.describe "Board.AddCard — a nested-entity-owned append's own duplicate-identity guard" do
  NESTED_ENTITY_APPEND_COLLISION_DOMAIN = File.join(InMemoryDomain::ROOT, "qa/stress_domains/nested_pieces")

  def open_workspace_step(reference)
    { "verb" => "NestedPieces::Workspace.Open", "args" => { "reference" => { "value" => reference } } }
  end

  def add_board_step(reference, number)
    {
      "verb" => "NestedPieces::Workspace.AddBoard",
      "args" => { "reference" => { "value" => reference }, "number" => { "value" => number } }
    }
  end

  def add_card_step(reference, number, sequence)
    {
      "verb" => "NestedPieces::Workspace.Board.AddCard",
      "args" => { "reference" => { "value" => reference }, "number" => { "value" => number }, "sequence" => sequence }
    }
  end

  # **The shrunk reproduction** — SW-nested_pieces-1789775748, seed 11, 100
  # steps shrunk to these 4. Ruby (pre-fix) silently appends a second Card
  # under sequence 168 rather than refusing it, so `board[:cards]` ends up
  # holding two identical elements and `element_of`'s own `find_index`
  # (BUG#3's own header) makes the first permanently the only one any
  # later command can ever address — the exact "silent duplicate becomes
  # unaddressable" harm BUG#13's own commit message already
  # named for the one-hop-shallower case.
  it "refuses a second AddCard under a sequence the board already holds, the same way append already does one hop up" do
    steps = [
      open_workspace_step("india"),
      add_board_step("india", 979),
      add_card_step("india", 979, 168),
      add_card_step("india", 979, 168)
    ]

    history = Hecks::Fuzzing::Replay.call(NESTED_ENTITY_APPEND_COLLISION_DOMAIN, steps)

    expect(history[:refusals].size).to eq(1)
    refusal = history[:refusals].first
    expect(refusal[:verb]).to eq("NestedPieces::Workspace.Board.AddCard")
    expect(refusal[:kind]).to eq("Hecks::Runtime::AlreadyExists")

    # **The duplicate never landed** — one Card, not two.
    workspace = history[:instances].values.find { |record| record[:reference].to_h == { value: "india" } }
    board = workspace[:boards].find { |b| b[:number].to_h == { value: 979 } }
    expect(board[:cards].map { |card| card[:sequence].to_h }).to eq([{ value: 168 }])
  end

  # Negative control, the same shape `entity_list_replace_identity_spec.rb`
  # and `banking_state_machine_spec.rb`'s own negative control give the
  # aggregate-level guard: two distinct sequences on the same board must
  # both land, not be refused as colliding with each other.
  it "accepts two AddCards under distinct sequences on the same board" do
    steps = [
      open_workspace_step("kilo"),
      add_board_step("kilo", 12),
      add_card_step("kilo", 12, 1),
      add_card_step("kilo", 12, 2)
    ]

    history = Hecks::Fuzzing::Replay.call(NESTED_ENTITY_APPEND_COLLISION_DOMAIN, steps)

    expect(history[:refusals]).to eq([])
    workspace = history[:instances].values.find { |record| record[:reference].to_h == { value: "kilo" } }
    board = workspace[:boards].find { |b| b[:number].to_h == { value: 12 } }
    expect(board[:cards].map { |card| card[:sequence].to_h }).to eq([{ value: 1 }, { value: 2 }])
  end
end
