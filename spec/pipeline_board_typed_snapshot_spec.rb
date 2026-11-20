# frozen_string_literal: true

require "spec_helper"
require_relative "support/typed_board_boot"

# ADR 0195 point 1: the board's read model is typed. A query that `returns list_of(Reading)` has
# each row an adapter answers built and checked as a `Reading`, and a `Reading` in state `unknown`
# is a row like any other. The PipelineBoard bluebook is booted with a stand-in behind the port,
# so no reader runs.
RSpec.describe "PipelineBoard typed rows" do
  include TypedBoardBoot

  scratch_directory :dir, "typed-board"

  let(:reading) { { key: "disk", label: "Disk free", value: "41.5", unit: "GB", state: "ok" } }
  let(:unknown) { { key: "wall", label: "Median CI wall", state: "unknown", note: "unknown: gh timed out" } }

  def refusal = /PipelineBoard\.Readings answered outside the domain/

  def readings(answer) = ask_typed_board(@dir, "Readings", answer)

  it "builds each row of a list_of(Reading) answer as a Reading, defaults filled" do
    expect(readings([reading]).first).to include(key: "disk", value: "41.5", state: "ok", note: "", since: "", fresh_at: "")
  end

  it "accepts a Reading in state unknown as a row, its reason in the note" do
    expect(readings([reading, unknown]).last).to include(state: "unknown", note: "unknown: gh timed out")
  end

  it "refuses a row whose state is none of the five words, naming the query" do
    expect { readings([reading.merge(state: "green")]) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /#{refusal.source}.*a reading's state/)
  end

  it "refuses a row that carries a field a Reading does not declare" do
    expect { readings([reading.merge(colour: "red")]) }.to raise_error(Hecks::Runtime::UnknownArgument, refusal)
  end

  it "refuses an answer that is not a list of rows" do
    expect { readings(reading) }.to raise_error(Hecks::Runtime::TypeMismatch, /Readings.*not a list of Reading row/)
  end
end
