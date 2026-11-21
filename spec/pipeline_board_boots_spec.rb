require "spec_helper"
require_relative "support/pipeline_board_world"

# The Boot hours metric: the reader's reading of the usage record, the day's hours as a
# reading beside the boot signals, and the tile's state for each. The reader is handed canned usage entries and a
# canned load, so the live record and the machine are never read.
RSpec.describe "the Boot hours metric" do
  include PipelineBoardWorld

  let(:now) { Time.utc(2026, 11, 9, 12, 0, 0) }
  let(:tiles) { Object.new.extend(Hecks::Adapters::PipelineBoard::BootTiles) }

  def reading(hours, budget: 1.0, last_hour: { "a" => 4 })
    { hours: hours, boots: 10, unmeasured: 0, last_hour: last_hour, budget: budget, load: 3.2, max_load: 8.0 }
  end

  def reader(rows)
    Hecks::Adapters::PipelineBoots.new(settings: { entries: ->(_date) { rows }, now: -> { now }, load: -> { 3.24 } })
  end

  it "reads the boots, who booted, and the load against its limit", :aggregate_failures do
    rows = [{ "boot_ms" => 1_800_000, "caller" => "a", "at" => (now - 60).iso8601 }]
    today = reader(rows).today

    expect(today).to include(hours: 0.5, boots: 1, last_hour: { "a" => 1 }, load: 3.2)
    expect(today[:budget]).to be_nil
  end

  it "is ok however many hours the day holds, which are a reading", :aggregate_failures do
    expect(tiles.boots(reading(5.0))).to include(state: "ok", value: 5.0, unit: "h")
    expect(tiles.boots(reading(0.5))[:detail]).to eq("budget 1.0 h; 10 boots; last hour: a 4; load 3.2 of 8.0")
  end

  it "fails on a boot storm, naming the caller", :aggregate_failures do
    tile = tiles.boots(reading(0.5).merge(storms: { "coder:w" => 31 }))

    expect(tile).to include(state: "failed")
    expect(tile[:detail]).to include("storm coder:w 31")
  end

  it "asks for attention while the boot share is over its mark at a load over the limit" do
    over = reading(0.5).merge(share: 40.0, share_mark: 25.0, load: 9.0)

    expect(tiles.boots(over)).to include(state: "attention")
  end

  it "stays ok when the boot share is over its mark at a load under the limit" do
    expect(tiles.boots(reading(0.5).merge(share: 40.0, share_mark: 25.0))).to include(state: "ok")
  end

  it "is ok, and says no budget is set, when the world sets none" do
    expect(tiles.boots(reading(5.0, budget: nil))).to include(state: "ok", detail: a_string_starting_with("no budget set"))
  end

  it "is unknown, with the reason, when the record could not be read" do
    expect(tiles.boots({ unknown: "no record" })).to include(state: "unknown", detail: "unknown: no record")
  end
end
