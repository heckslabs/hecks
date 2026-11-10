# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/pipeline_board/adapters/pipeline_stages"

# The event-tap lines of a fake journal: one Work item's own events, written to a temporary file
# and read through the Journal reader. The times are those measured by hand for
# ci-observe-follows-the-squash-merge.
module CycleJournal
  NOW = Time.parse("2026-11-09T22:30:00Z")

  def line(at, aggregate, id, event, links = {})
    { "kind" => "event", "at" => at, "aggregate" => aggregate, "id" => id, "event" => event, "links" => links }
  end

  def landed_item(key, review, offset = 0)
    stamp = ->(clock) { (Time.parse("2026-11-09T#{clock}Z") + offset).utc.iso8601 }
    [line(stamp.call("21:30:00"), "Tickets::Work", key, "WorkPlanned"),
     line(stamp.call("21:37:15"), "Tickets::Work", key, "WorkStarted"),
     line(stamp.call("21:38:37"), "Agents::PlanReview", review, "PlanReviewRequested", "work" => key),
     line(stamp.call("21:39:16"), "Agents::PlanReview", review, "PlanReviewed"),
     line(stamp.call("21:52:25"), "Hecks::Landing", "landing-#{review}", "BranchLanded", "branch" => key)]
  end

  def in_flight
    [line("2026-11-09T22:00:00Z", "Tickets::Work", "busy", "WorkPlanned"),
     line("2026-11-09T22:10:00Z", "Tickets::Work", "busy", "WorkStarted")]
  end

  def journal(lines)
    path = File.join(Dir.mktmpdir("cycles"), "events.jsonl")
    File.write(path, lines.map { |entry| "#{JSON.generate(entry)}\n" }.join)
    Hecks::Adapters::PipelineJournal.new(settings: { tap: path, trace: ->(*) { { "events" => [] } } })
  end

  def cycles = Hecks::Adapters::PipelineBoard::Cycles

  def built(lines) = cycles.build(journal(lines).cycle_events(cycles.event_names), NOW)

  def stage(cycle, name) = cycle[:stages].find { |entry| entry[:stage] == name }
end

RSpec.describe "the cycle of a Work item" do
  include CycleJournal

  it "measures each stage of a landed item exactly", :aggregate_failures do
    cycle = built(landed_item("ci-observe", "r1"))[:cycles].first
    expect(cycle[:stages].map { |entry| [entry[:stage], entry[:seconds]] })
      .to eq([["fill", 435], ["planning", 82], ["review", 39], ["implementing", 789]])
    expect(cycle).to include(work: "ci-observe", seconds: 1345, open: nil)
  end

  it "shows the open stage of an item still in flight", :aggregate_failures do
    cycle = built(in_flight)[:cycles].first
    expect(cycle[:open]).to eq("planning")
    expect(stage(cycle, "planning")).to include(open: true, seconds: 1200, end: nil)
  end

  it "joins a review's end by the review's own id, not by another item's" do
    lines = landed_item("a", "r1") + landed_item("b", "r2", 60)
    expect(stage(built(lines)[:cycles].first, "review")[:seconds]).to eq(39)
  end

  it "keys an event by its id when its link holds a printed object, not a value" do
    lines = [line("2026-11-09T22:00:00Z", "Tickets::Work", "busy", "WorkPlanned", "work" => "#<Hecks::Runtime::Value:0x1>")]
    expect(built(lines)[:cycles].map { |cycle| cycle[:work] }).to eq(["busy"])
  end

  it "lists the newest item first" do
    expect(built(landed_item("a", "r1") + in_flight)[:cycles].map { |cycle| cycle[:work] }).to eq(%w[busy a])
  end

  it "gives the median and the percentile of each stage over the closed stages", :aggregate_failures do
    lines = landed_item("a", "r1") + landed_item("b", "r2", 3600) + in_flight
    fill = built(lines)[:stats].find { |entry| entry[:stage] == "fill" }
    expect(fill).to include(median: 435, percentile: 600, items: 3)
    expect(built(lines)[:stats].map { |entry| entry[:stage] }).to eq(%w[fill planning review implementing])
  end
end
