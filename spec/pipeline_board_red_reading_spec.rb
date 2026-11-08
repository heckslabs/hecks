# frozen_string_literal: true

require "spec_helper"
require "time"
require "hecks/pipeline_board/adapters/pipeline_stages"

# How long main has been red, read once: from the standing red flag when there is one, else from
# the CI runs (oldest first), where the last green run and the first red run after it start the
# count. The Main red tile and the strip's flag row say the same minutes.
RSpec.describe Hecks::Adapters::PipelineBoard::RedReading do
  let(:now) { Time.parse("2026-11-07T12:00:00Z") }
  let(:runs) do
    [ci("g1", "08:00", "success"), ci("r1", "09:00", "failure"), ci("g2", "10:00", "success"),
     ci("r2", "10:30", "failure"), ci("r3", "11:00", "failure")]
  end
  let(:flag) do
    { "id" => "flag-r2", "commit" => "r2r2r2r2r2r2", "raised_at" => "2026-11-07T10:30:00Z", "runs" => [],
      "checkins" => [{ "session" => "s1", "taking" => "red-ci" }] }
  end

  def ci(sha, at, conclusion, status: "completed")
    { sha: sha, started: "2026-11-07T#{at}:00Z", wall_minutes: 5.0, status: status, conclusion: conclusion }
  end

  def red_tile(list, marker) = Hecks::Adapters::PipelineBoard::Metrics.red_for(list, marker, now)

  it "names the last green run, not the oldest, and the first red run after it", :aggregate_failures do
    reading = described_class.new(runs, nil, now)
    expect(reading.last_green).to eq("g2")
    expect(reading.culprit).to eq("r2")
  end

  it "counts the minutes from the finish of the first red run after the last green" do
    expect(described_class.new(runs, nil, now).minutes).to eq(85)
  end

  it "says the Main red tile in hours from the same reading", :aggregate_failures do
    tile = red_tile(runs, nil)
    expect(tile[:value]).to eq(1.4)
    expect(tile[:detail]).to include("culprit r2", "last green g2")
  end

  it "reads a standing flag first: its commit, its raised time and who checked in", :aggregate_failures do
    reading = described_class.new(runs, flag, now)
    expect([reading.culprit, reading.minutes]).to eq(["r2r2r2r2r2", 90])
    expect(reading.fixer).to eq("s1 takes red-ci")
  end

  it "names the landed fix branch as the fixer once one is recorded" do
    landed = flag.merge("fix_branch" => "red-ci", "fix_tip" => "f1f1f1f1f1f1f1")
    expect(described_class.new(runs, landed, now).fixer).to eq("red-ci at f1f1f1f1f1")
  end

  it "keeps the tile red under a standing flag while the newest run is still going" do
    going = runs + [ci("r4", "11:50", "", status: "in_progress")]
    expect(red_tile(going, flag)[:value]).to eq(1.5)
  end

  it "says CI is still running when no flag stands and the newest run is going" do
    going = runs + [ci("r4", "11:50", "", status: "in_progress")]
    expect(red_tile(going, nil)[:detail]).to eq("unknown: CI is still running on r4")
  end

  it "leaves the tile empty when no green run is in the window", :aggregate_failures do
    tile = red_tile(runs.drop(3), nil)
    expect(tile[:value]).to be_nil
    expect(tile[:detail]).to eq("no green run in the window")
  end

  it "reads the runs when the flag could not be read or has no raised time", :aggregate_failures do
    expect(described_class.new(runs, { unknown: "git failed" }, now).culprit).to eq("r2")
    expect(described_class.new(runs, flag.except("raised_at"), now).minutes).to be_nil
  end

  it "gives the tile and the strip's flag row the same minutes", :aggregate_failures do
    row = Hecks::Adapters::PipelineBoard::Strip.flag(flag, now).first
    expect(row[:detail]).to include("red for 90 min")
    expect(red_tile(runs, flag)[:value]).to eq(1.5)
  end
end
