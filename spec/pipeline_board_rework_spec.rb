# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"

# The rework rate, read from the landed Work items and the event log: the `ReworkCheck` rows of
# pipeline_board.bluebook say what counts, the `Verdict` rows say the state.
module ReworkLedger
  AT = "2026-11-20T10:00:00Z"

  def landed(count = 10)
    (1..count).map { |n| { slug: "item-#{n}", title: "Item #{n}", epic: "e1", landing: "abc#{n}" } }
  end

  def still_item = { slug: "still-1", title: "Still red after item 4", epic: "e1", landing: "abc99" }

  def event(aggregate, name, id, links = {}) = { aggregate: aggregate, name: name, id: id, links: links, at: AT }

  def reopened = event("Tickets::Work", "WorkReopened", "item-1")

  def reverted = event("RedEpisode", "EpisodeRevertMade", "ep-1", { work: "item-2" })

  def read(work, events) = Hecks::Adapters::PipelineBoard::Rework.build(work, events, AT)

  def reading(key, work, events) = read(work, events).find { |row| row[:key] == key }
end

RSpec.describe "the board's rework rate" do
  include ReworkLedger

  it "reads 30 percent: one reopened, one reverted and one still follow-up among ten landed", :aggregate_failures do
    rate = reading("rework_rate", landed(9) + [still_item], [reopened, reverted])
    expect(rate[:value]).to eq("30")
    expect(rate[:unit]).to eq("%")
  end

  it "counts each kind on its own row", :aggregate_failures do
    rows = read(landed(9) + [still_item], [reopened, reverted])
    expect(rows.to_h { |row| [row[:key], row[:value]] }).to include("reopened" => "1", "reverted" => "1", "still" => "1")
  end

  it "reads no reading, never zero, when nothing has landed", :aggregate_failures do
    rate = reading("rework_rate", [], [])
    expect(rate[:state]).to eq("unknown")
    expect(rate[:value]).to eq("")
  end

  it "reads 0 percent when items landed and none came back" do
    expect(reading("rework_rate", landed, [])[:value]).to eq("0")
  end

  it "reads no reading when the event log could not be read", :aggregate_failures do
    rate = reading("rework_rate", landed, nil)
    expect(rate[:state]).to eq("unknown")
    expect(rate[:note]).to include("no reading")
  end
end
