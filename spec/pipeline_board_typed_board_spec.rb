# frozen_string_literal: true

require "spec_helper"
require_relative "support/typed_board_boot"

# ADR 0195 point 1: `Board` answers the one `Snapshot` row, and the lists it holds are checked row
# by row as the value objects the bluebook declares for them. A nested row is kept as the adapter
# answered it, so the adapter fills every field; only a row of a query's own list has its defaults
# filled by the runtime.
RSpec.describe "PipelineBoard Board query" do
  include TypedBoardBoot

  scratch_directory :dir, "typed-board"

  let(:reading) { { key: "disk", label: "Disk free", value: "41.5", unit: "GB", state: "ok" } }

  def snapshot(lists = {})
    { generated_at: "2026-11-20T10:00:00Z", stages: [], readings: [], stuck: [], roles: [], runs: [], train: [],
      release: { latest_tag: "v7.0.0" }, events: [] }.merge(lists)
  end

  def board(lists = {}) = ask_typed_board(@dir, "Board", snapshot(lists)).first

  it "builds a Stage with its place in the strip" do
    rows = ask_typed_board(@dir, "Stages", [reading.merge(key: "ci", label: "CI", order: 6)])
    expect(rows.first).to include(key: "ci", order: 6, state: "ok")
  end

  it "holds the Reading rows the Snapshot was answered with" do
    expect(board(readings: [reading])[:readings].first).to include(key: "disk", unit: "GB", state: "ok")
  end

  it "holds the StuckItem rows the Snapshot was answered with" do
    expect(board(stuck: [{ kind: "red_main", what: "main is red" }])[:stuck].first).to include(kind: "red_main")
  end

  it "builds the ReleaseCard the Snapshot holds" do
    expect(board[:release]).to include(latest_tag: "v7.0.0", holds: "")
  end

  it "refuses a Snapshot whose nested Reading is none of the five states" do
    expect { board(readings: [reading.merge(state: "green")]) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /a reading's state/)
  end
end
