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

  # Replays a workspace with one board and two AddCards, one per given sequence.
  def replay_cards(reference, number, sequences)
    steps = [open_workspace_step(reference), add_board_step(reference, number)]
    steps += sequences.map { |sequence| add_card_step(reference, number, sequence) }
    Hecks::Fuzzing::Replay.call(NESTED_ENTITY_APPEND_COLLISION_DOMAIN, steps)
  end

  def card_sequences(history, reference, number)
    workspace = history[:instances].values.find { |record| record[:reference].to_h == { value: reference } }
    board = workspace[:boards].find { |b| b[:number].to_h == { value: number } }
    board[:cards].map { |card| card[:sequence].to_h }
  end

  # Shrunk sweep reproduction (nested_pieces, seed 11): a second Card under a held sequence is
  # refused, else `find_index` leaves the duplicate permanently unaddressable.
  it "refuses a second AddCard under a sequence the board already holds, the same way append already does one hop up",
     :aggregate_failures do
    history = replay_cards("india", 979, [168, 168])

    expect(history[:refusals].size).to eq(1)
    expect(history[:refusals].first).to include(verb: "NestedPieces::Workspace.Board.AddCard",
                                                kind: "Hecks::Runtime::AlreadyExists")
    expect(card_sequences(history, "india", 979)).to eq([{ value: 168 }])
  end

  # Negative control: two distinct sequences on the same board must both land.
  it "accepts two AddCards under distinct sequences on the same board", :aggregate_failures do
    history = replay_cards("kilo", 12, [1, 2])

    expect(history[:refusals]).to eq([])
    expect(card_sequences(history, "kilo", 12)).to eq([{ value: 1 }, { value: 2 }])
  end
end
