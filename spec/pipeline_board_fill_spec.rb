require "spec_helper"
require_relative "support/pipeline_board_world"

# The board's fill tile reads the report the last rolling fill recorded and starts no process; only
# without one does it ask a launcher, and it keeps that answer for a minute.
RSpec.describe Hecks::Adapters::PipelineFill do
  let(:report) do
    ["load 3.0 (limit 8.0, 12 cpus); started 4 of cap 6; this fill would start 1; frozen: none; at 2026-11-09T07:00:00Z",
     "would start alpha: Outcome: alpha",
     "beta skipped: cap 6 reached"].join("\n")
  end
  let(:runner) { instance_double(Proc, call: report) }

  def reader(recorded, **settings)
    described_class.new(settings: { report: -> { recorded }, runner: runner }.merge(settings))
  end

  it "parses the recorded report", :aggregate_failures do
    fill = reader(report).preview

    expect(fill).to include(load: 3.0, limit: 8.0, cap: 6, started: 4, at: "2026-11-09T07:00:00Z")
    expect(fill[:would_start]).to eq([{ slug: "alpha", title: "Outcome: alpha" }])
    expect(fill[:skipped]).to eq([{ slug: "beta", reason: "cap 6 reached" }])
  end

  it "starts no process when a report is recorded, however old it is" do
    reader(report).preview

    expect(runner).not_to have_received(:call)
  end

  it "shows a report that states no time, with no time" do
    expect(reader(report.sub("; at 2026-11-09T07:00:00Z", "")).preview[:at]).to be_nil
  end

  it "asks the launcher once while no report is recorded, and keeps the answer", :aggregate_failures do
    fill = reader(nil)

    2.times { fill.preview }

    expect(runner).to have_received(:call).once
    expect(fill.preview).to include(cap: 6)
  end

  it "asks the launcher again after a minute where no report stands" do
    ticks = [0.0]
    fill = reader(nil, cache_clock: -> { ticks.first })
    [0.0, 61.0].each { |now| (ticks[0] = now) && fill.preview }
    expect(runner).to have_received(:call).twice
  end

  it "reads a confirmed report: the items it started, and the ones that went back", :aggregate_failures do
    confirmed = [report.lines.first.strip, "started alpha", "started beta (then refused: busy)",
                 "yielded gamma: cap"].join("\n")
    fill = reader(confirmed).preview
    expect(fill[:launched]).to eq([{ slug: "alpha" }, { slug: "beta" }])
    expect(fill[:skipped]).to eq([{ slug: "gamma", reason: "cap" }])
  end

  it "refuses a report it cannot read" do
    garbled = ->(*) { "not a fill report" }

    expect { reader(nil, runner: garbled).preview }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable)
  end
end
