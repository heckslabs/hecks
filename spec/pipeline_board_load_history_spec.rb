# frozen_string_literal: true

require "spec_helper"

require "hecks/pipeline_board/adapters/load_history"

# The machine's load over the last minutes, for the board's load chart: sampled without a program,
# kept for fifteen minutes, and handed to the page with the limit a fill stops at.
RSpec.describe Hecks::Adapters::PipelineBoard::LoadHistory do
  let(:loads) { [3.14159, 12.5] }
  let(:clock) { [Time.utc(2026, 11, 14, 12, 0, 0), Time.utc(2026, 11, 14, 12, 0, 5)] }
  let(:history) { described_class.new(limit: 10, load: -> { loads.shift }, now: -> { clock.shift }) }

  it "keeps each sample with its time, the load rounded, oldest first" do
    2.times { history.sample }
    expect(history.reading[:samples]).to eq([["2026-11-14T12:00:00Z", 3.14], ["2026-11-14T12:00:05Z", 12.5]])
  end

  it "hands the page the limit, the cores and the seconds between samples", :aggregate_failures do
    reading = history.reading
    expect(reading.values_at(:limit, :every)).to eq([10.0, 5])
    expect(reading[:cores]).to be_positive
  end

  it "forgets the samples older than the fifteen minutes it keeps" do
    steady = described_class.new(limit: 10, load: -> { 1.0 }, now: -> { Time.utc(2026, 11, 14) })
    (described_class::KEPT + 20).times { steady.sample }
    expect(steady.reading[:samples].size).to eq(described_class::KEPT)
  end

  it "has no reading until a board stands one" do
    allow(described_class).to receive(:shared).and_return(nil)
    expect(described_class.reading).to be_nil
  end
end
