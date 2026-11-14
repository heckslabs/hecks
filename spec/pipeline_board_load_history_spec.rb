# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"

require "hecks/pipeline_board/adapters/load_history"

# The machine's load over the last hours, for the board's load chart: sampled without a program,
# kept for three hours and across a board's restart, and handed to the page with the limit a fill
# stops at.
RSpec.describe Hecks::Adapters::PipelineBoard::LoadHistory do
  let(:loads) { [3.14159, 12.5] }
  let(:clock) { [Time.utc(2026, 11, 14, 12, 0, 0), Time.utc(2026, 11, 14, 12, 0, 10)] }
  let(:history) { described_class.new(limit: 10, load: -> { loads.shift }, now: -> { clock.shift }) }
  let(:noon) { Time.utc(2026, 11, 14, 12) }

  # A history that keeps its samples in a file of the given folder, at a fixed time.
  def kept_in(folder, at = noon)
    described_class.new(limit: 10, load: -> { 2.0 }, now: -> { at }, path: File.join(folder, "load.json"))
  end

  it "keeps each sample with its time, the load rounded, oldest first" do
    2.times { history.sample }
    expect(history.reading[:samples]).to eq([["2026-11-14T12:00:00Z", 3.14], ["2026-11-14T12:00:10Z", 12.5]])
  end

  it "hands the page the limit, the cores and the seconds between samples", :aggregate_failures do
    reading = history.reading
    expect(reading.values_at(:limit, :every)).to eq([10.0, 10])
    expect(reading[:cores]).to be_positive
  end

  it "forgets the samples older than the three hours it keeps" do
    steady = described_class.new(limit: 10, load: -> { 1.0 }, now: -> { Time.utc(2026, 11, 14) })
    (described_class::KEPT + 20).times { steady.sample }
    expect(steady.reading[:samples].size).to eq(described_class::KEPT)
  end

  it "has no reading until a board stands one" do
    allow(described_class).to receive(:shared).and_return(nil)
    expect(described_class.reading).to be_nil
  end

  it "starts from the samples the last board left, so a restart keeps the chart" do
    Dir.mktmpdir do |folder|
      kept_in(folder).sample
      expect(kept_in(folder).reading[:samples]).to eq([["2026-11-14T12:00:00Z", 2.0]])
    end
  end

  it "leaves behind the samples older than the time it keeps" do
    Dir.mktmpdir do |folder|
      kept_in(folder, noon - (4 * 3600)).sample
      expect(kept_in(folder).reading[:samples]).to be_empty
    end
  end

  it "starts empty from a file it cannot read as samples" do
    Dir.mktmpdir do |folder|
      File.write(File.join(folder, "load.json"), "not json")
      expect(kept_in(folder).reading[:samples]).to be_empty
    end
  end
end
