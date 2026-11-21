# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/board_rows"
require_relative "support/status_facts"

# The rest of `Now`: the throughput windows, the blocked runs, a section that was not read, and
# the shape the bluebook declares for the whole row.
RSpec.describe Hecks::Adapters::PipelineBoard::PipelineStatus, ".build (rows)" do
  include BoardRows
  include StatusFacts

  def described_class = Hecks::Adapters::PipelineBoard::PipelineStatus

  let(:session) { { run: "r1", status: "blocked", idle_seconds: 600, detail: "[owner] push?\nmore", question_kind: "owner" } }

  it "counts landings per window with their rate" do
    landed = { "a" => ago(600), "b" => ago(1200), "c" => ago(7200) }
    hour = status(landed_times: landed, fill: fill)[:throughput].first
    expect(hour).to include(window: "last hour", landings: 2, per_hour: "2.0")
  end

  it "counts from a mark the caller names" do
    rows = status({ landed_times: { "a" => ago(600) }, fill: fill }, ago(3600))[:throughput]
    expect(rows.last).to include(landings: 1)
  end

  it "lists a blocked run with its question's first line and kind" do
    listed = { run: "r1", minutes: 10, first_line: "[owner] push?", kind: "owner" }
    expect(status(sessions: [session], fill: fill)[:blocked]).to eq([listed])
  end

  it "answers without raising when no section was read" do
    row = status(fill: { unknown: "x" }, landed_times: { unknown: "y" }, cycle_events: { unknown: "z" })
    expect(row).to include(items: [], blocked: [])
  end

  it "is the shape the bluebook declares" do
    row = status(overloads: [{ reason: "x" }], fill: fill, landed_times: { "a" => ago(60) }, sessions: [session])
    expect(built("Status", row)).to include(:why_idle, :throughput, :blocked)
  end
end
