# frozen_string_literal: true

require "spec_helper"

require "hecks/pipeline_board/adapters/load_causes"

# What is using the CPU, for the board's load chart: the busiest process classes, read without
# changing anything and handed to the page with when they were read.
RSpec.describe Hecks::Adapters::PipelineBoard::LoadCauses do
  let(:rows) do
    Array.new(8) { |i| { "name" => "p#{i}", "count" => i + 1, "cpu" => 100.0 - i, "session" => "", "extra" => 1 } }
  end
  let(:causes) { described_class.new(rows: -> { rows }, now: -> { Time.utc(2026, 11, 14, 12) }) }

  it "has nothing to show before its first read" do
    expect(causes.reading).to eq({ at: nil, classes: [] })
  end

  it "keeps the busiest classes, with how many run and the CPU they take", :aggregate_failures do
    causes.read
    expect(causes.reading[:classes].size).to eq(described_class::SHOWN)
    expect(causes.reading[:classes].first).to eq({ name: "p0", count: 1, cpu: 100.0, session: "" })
  end

  it "says when it read them" do
    causes.read
    expect(causes.reading[:at]).to eq("2026-11-14T12:00:00Z")
  end

  it "has no reading until a board stands one" do
    allow(described_class).to receive(:shared).and_return(nil)
    expect(described_class.reading).to be_nil
  end
end
