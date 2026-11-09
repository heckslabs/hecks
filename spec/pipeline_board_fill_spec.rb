require "spec_helper"
require_relative "support/pipeline_board_world"

# The board's fill tile reads the report the last rolling fill recorded and starts no process; only
# without one does it ask a launcher, and it keeps that answer.
RSpec.describe Hecks::Adapters::PipelineFill do
  let(:ran_at) { Time.utc(2026, 11, 9, 7, 0, 0) }
  let(:report) do
    ["load 3.0 (limit 8.0, 12 cpus); started 4 of cap 6; this fill would start 1; frozen: none; at 2026-11-09T07:00:00Z",
     "would start alpha: Outcome: alpha",
     "beta skipped: cap 6 reached"].join("\n")
  end
  let(:runner) { instance_double(Proc, call: report) }

  # A reader whose clock stands one minute after the report was made.
  def reader(recorded, **settings)
    described_class.new(settings: { report: -> { recorded }, runner: runner, now: -> { ran_at + 60 } }.merge(settings))
  end

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

  # Previews the recorded report with the clock this many seconds after the time it states.
  def preview_after(seconds, **settings)
    reader(report, now: -> { ran_at + seconds }, fresh_seconds: 900, **settings).preview
  end

  it "asks the launcher once the time a report states is past the fresh window" do
    preview_after(901)
    expect(runner).to have_received(:call).once
  end

  it "keeps a report current while the time it states is young" do
    preview_after(899)
    expect(runner).not_to have_received(:call)
  end

  it "does not take a report for fresh because the board has just started and not seen it before" do
    fill = reader(report, now: -> { ran_at + 86_400 })
    fill.preview
    expect(runner).to have_received(:call).once
  end

  it "treats a report that states no time as stale" do
    old_form = report.sub("; at 2026-11-09T07:00:00Z", "")
    reader(old_form).preview
    expect(runner).to have_received(:call).once
  end

  # Previews twice with the previews' own clock this many seconds apart, a day after the recorded
  # report was made; answers how many times the launcher ran.
  def launcher_runs(recorded, gap)
    ticks = [0.0]
    runs = []
    counting = ->(*) { (runs << 1) && report }
    fill = reader(recorded, runner: counting, now: -> { ran_at + 86_400 }, cache_clock: -> { ticks.first })
    fill.preview
    ticks[0] += gap
    fill.preview
    runs.size
  end

  it "keeps a launcher's answer past a minute where only a stale report stands" do
    expect(launcher_runs(report, 200)).to eq(1)
  end

  it "asks the launcher again after five minutes where only a stale report stands" do
    expect(launcher_runs(report, 301)).to eq(2)
  end

  it "asks the launcher again after a minute where no report stands" do
    expect(launcher_runs(nil, 61)).to eq(2)
  end

  it "refuses a report it cannot read" do
    garbled = ->(*) { "not a fill report" }

    expect { reader(nil, runner: garbled).preview }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable)
  end
end
