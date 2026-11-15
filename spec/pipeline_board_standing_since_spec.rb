# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

require "hecks/pipeline_board/adapters/pipeline_stages/standing_since"

# The board says since when a stage or a metric has been in its state: the time of the first
# reading that found it so, kept across the board's restarts.
RSpec.describe Hecks::Adapters::PipelineBoard::StandingSince do
  let(:noon) { Time.utc(2026, 11, 14, 12, 0, 0) }
  let(:later) { noon + 600 }

  def failed = [{ name: "Integration", state: "failed" }]

  it "stamps a row with the time its state was first read" do
    expect(described_class.new.stamp("stage", failed, noon).first[:since]).to eq("2026-11-14T12:00:00Z")
  end

  it "keeps that time while the state stands" do
    since = described_class.new.tap { |held| held.stamp("stage", failed, noon) }
    expect(since.stamp("stage", failed, later).first[:since]).to eq("2026-11-14T12:00:00Z")
  end

  it "starts again when the state moves" do
    since = described_class.new.tap { |held| held.stamp("stage", failed, noon) }
    expect(since.stamp("stage", [{ name: "Integration", state: "ok" }], later).first[:since]).to eq("2026-11-14T12:10:00Z")
  end

  it "reads back what the last board left in its file" do
    Dir.mktmpdir do |folder|
      path = File.join(folder, "since.json")
      described_class.new(path: path).stamp("stage", failed, noon)
      expect(described_class.new(path: path).stamp("stage", failed, later).first[:since]).to eq("2026-11-14T12:00:00Z")
    end
  end

  it "leaves a section that was not read as it is" do
    expect(described_class.new.stamp("stage", { unknown: "not read" }, noon)).to eq(unknown: "not read")
  end

  it "stamps nothing, and writes no file, when no board stands" do
    expect(described_class.over({ stages: failed, metrics: [] }, noon)).to eq(stages: failed, metrics: [])
  end
end
