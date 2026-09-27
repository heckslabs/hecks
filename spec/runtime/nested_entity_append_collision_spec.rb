require "spec_helper"
require "hecks/fuzzing"

# An `append:` onto an entity-owned nested list must refuse a duplicate identity, as the
# aggregate-owned list does; Rust's generated code refuses with `AlreadyExists` for both.
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

  # Shrunk sweep reproduction (nested_pieces, seed 11): a second Card under a held sequence is
  # refused, else `find_index` leaves the duplicate permanently unaddressable.
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

    workspace = history[:instances].values.find { |record| record[:reference].to_h == { value: "india" } }
    board = workspace[:boards].find { |b| b[:number].to_h == { value: 979 } }
    expect(board[:cards].map { |card| card[:sequence].to_h }).to eq([{ value: 168 }])
  end

  # Negative control: two distinct sequences on the same board must both land.
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
