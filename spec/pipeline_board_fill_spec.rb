require "spec_helper"
require_relative "support/pipeline_board_world"

# The board's fill tile reads the report the last rolling fill recorded and starts no process; only
# without one does it ask a launcher, and it keeps that answer.
RSpec.describe Hecks::Adapters::PipelineFill do
  let(:report) do
    ["load 3.0 (limit 8.0, 12 cpus); started 4 of cap 6; this fill would start 1; frozen: none",
     "would start alpha: Outcome: alpha",
     "beta skipped: cap 6 reached"].join("\n")
  end
  let(:runner) { instance_double(Proc, call: report) }

  def reader(recorded, **settings) = described_class.new(settings: { report: -> { recorded }, runner: runner }.merge(settings))

  it "parses the recorded report", :aggregate_failures do
    fill = reader(report).preview

    expect(fill).to include(load: 3.0, limit: 8.0, cap: 6, started: 4)
    expect(fill[:would_start]).to eq([{ slug: "alpha", title: "Outcome: alpha" }])
    expect(fill[:skipped]).to eq([{ slug: "beta", reason: "cap 6 reached" }])
  end

  it "starts no process when a report is recorded" do
    reader(report).preview

    expect(runner).not_to have_received(:call)
  end

  it "asks the launcher once while no report is recorded, and keeps the answer", :aggregate_failures do
    fill = reader(nil)

    2.times { fill.preview }

    expect(runner).to have_received(:call).once
    expect(fill.preview).to include(cap: 6)
  end

  it "refuses a report it cannot read" do
    expect { reader("not a fill report").preview }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable)
  end
end
