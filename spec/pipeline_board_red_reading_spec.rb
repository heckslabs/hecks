# frozen_string_literal: true

require "spec_helper"
require "time"
require "hecks/pipeline_board/adapters/pipeline_stages"

# How long main has been red, read from the CI runs (oldest first): the last green run and the
# first red run after it start the count.
RSpec.describe Hecks::Adapters::PipelineBoard::RedReading do
  let(:now) { Time.parse("2026-11-07T12:00:00Z") }
  let(:runs) do
    [ci("g1", "08:00", "success"), ci("r1", "09:00", "failure"), ci("g2", "10:00", "success"),
     ci("r2", "10:30", "failure"), ci("r3", "11:00", "failure")]
  end

  def ci(sha, at, conclusion, status: "completed")
    { sha: sha, started: "2026-11-07T#{at}:00Z", wall_minutes: 5.0, status: status, conclusion: conclusion }
  end

  def red_tile(list) = Hecks::Adapters::PipelineBoard::Metrics.red_for(list, now)

  it "names the last green run, not the oldest, and the first red run after it", :aggregate_failures do
    reading = described_class.new(runs, now)
    expect(reading.last_green).to eq("g2")
    expect(reading.culprit).to eq("r2")
  end

  it "counts the minutes from the finish of the first red run after the last green" do
    expect(described_class.new(runs, now).minutes).to eq(85)
  end

  it "says the Main red tile in hours from the same reading", :aggregate_failures do
    tile = red_tile(runs)
    expect(tile[:value]).to eq(1.4)
    expect(tile[:detail]).to include("culprit r2", "last green g2")
  end

  it "says CI is still running when the newest run is going" do
    going = runs + [ci("r4", "11:50", "", status: "in_progress")]
    expect(red_tile(going)[:detail]).to eq("unknown: CI is still running on r4")
  end

  it "leaves the tile empty when no green run is in the window", :aggregate_failures do
    tile = red_tile(runs.drop(3))
    expect(tile[:value]).to be_nil
    expect(tile[:detail]).to eq("no green run in the window")
  end
end
