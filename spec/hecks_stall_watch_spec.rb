require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# A stall is an opening event of a `StallKind` row whose closing event has not come within the
# row's minutes. A look (`StallWatch.Detect`) reads a throwaway tap and files each stall once, as a
# `Stall` and a Tickets work item of the same key, which the dispatch fill starts after red.
RSpec.describe "StallWatch" do
  include_context "with a stall watch tap"

  it "sees every opening line no closing line followed, with how long it waited", :aggregate_failures do
    write_tap
    rows = watching.unclosed(run: { value: "look-1" })

    expect(rows.map { |row| row[:stall] }).to eq(%w[stall-plan-review-late stall-plan-review-young])
    expect(rows.first).to include(id: "look-1", waited: 30, minutes: 20, fixer: "orchestrator")
  end

  it "files a stall past its minutes as one Stall and one work item of the same key", :aggregate_failures do
    write_tap
    detect("look-1")

    expect(keys("Hecks", "Stall", :stall)).to eq(%w[stall-plan-review-late])
    expect(keys("Tickets", "Work", :work)).to eq(%w[stall-plan-review-late])
  end

  it "files a stall once, however many looks see it" do
    write_tap
    detect("look-1")
    detect("look-2")

    expect(registry.event_log.map(&:name).count("StallFiled")).to eq(1)
  end

  it "looks for stalls on every beat of the clock" do
    File.write(tap, "")
    with_tap { dispatch("Hecks::Heartbeat.Beat", beat: { value: "beat-1" }) }

    expect(registry.event_log.map(&:name)).to include("StallDetectRequested")
  end

  it "starts a filed stall after a red work item and before every other one" do
    %w[stall-train-events now-item].each { |work| plan(work, "now") }
    %w[stall-plan-review-late red-spec].each { |work| plan(work) }

    expect(Hecks::Adapters::Dispatching::WorkItems.new(registry).planned.map(&:key))
      .to eq(%w[red-spec stall-plan-review-late now-item stall-train-events])
  end
end
