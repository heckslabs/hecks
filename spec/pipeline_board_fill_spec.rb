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

  it "reads a confirmed report: the items it started, and the ones that went back", :aggregate_failures do
    confirmed = [report.lines.first.strip, "started alpha", "started beta (then refused: busy)",
                 "yielded gamma: cap"].join("\n")
    fill = reader(confirmed).preview
    expect(fill[:launched]).to eq([{ slug: "alpha" }, { slug: "beta" }])
    expect(fill[:skipped]).to eq([{ slug: "gamma", reason: "cap" }])
  end

  # Previews a recorded report at each of the given times, in seconds.
  def previews_at(*times)
    now = [times.first]
    fill = reader(report, clock: -> { now.first }, fresh_seconds: 900)
    times.each do |at|
      now[0] = at
      fill.preview
    end
  end

  it "asks the launcher once an unchanged report has stood past the fresh window" do
    previews_at(0.0, 901.0)
    expect(runner).to have_received(:call).once
  end

  it "keeps a report current while it is young" do
    previews_at(0.0, 899.0)
    expect(runner).not_to have_received(:call)
  end

  it "refuses a report it cannot read" do
    expect { reader("not a fill report").preview }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable)
  end
end
