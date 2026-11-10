# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/pipeline_board/adapters/pipeline_stages"

# The event-tap lines of a fake journal: one Work item's own events, written to a temporary file
# and read through the Journal reader. The times are those measured by hand for
# ci-observe-follows-the-squash-merge: started 21:37:15Z, plan review 21:38:37Z, verdict 21:39:16Z,
# landed 21:52:25Z, pull request opened 22:05:13Z, merged 22:18:09Z.
module CycleJournal
  NOW = Time.parse("2026-11-09T22:30:00Z")

  def line(at, aggregate, id, event, links = {})
    { "kind" => "event", "at" => at, "aggregate" => aggregate, "id" => id, "event" => event, "links" => links }
  end

  def landed_item(key, review, offset = 0)
    [line(stamp("21:30:00", offset), "Tickets::Work", key, "WorkPlanned"),
     line(stamp("21:37:15", offset), "Tickets::Work", key, "WorkStarted"),
     line(stamp("21:37:18", offset), "Hecks::AgentRun", key, "AgentStarted"),
     line(stamp("21:38:37", offset), "Agents::PlanReview", review, "PlanReviewRequested", "work" => key),
     line(stamp("21:39:16", offset), "Agents::PlanReview", review, "PlanReviewed"),
     line(stamp("21:52:25", offset), "Hecks::Landing", "landing-#{review}", "BranchLanded",
          "branch" => key, "landed" => sha(key))]
  end

  # What follows the landing on main: verified, boarded as a pull request, merged, pulled.
  def integrated(key, offset = 0)
    [line(stamp("21:58:00", offset), "Hecks::Integration", "run-#{key}", "MainVerified", "landed" => sha(key)),
     line(stamp("22:05:13", offset), "Hecks::SendTrain", "train-#{key}", "BoardingQueued", "boarded" => sha(key)),
     line(stamp("22:18:09", offset), "Hecks::SendTrain", "train-#{key}", "BranchPushed", "boarded" => sha(key)),
     line(stamp("22:19:00", offset), "Hecks::LinkedTree", "pull-#{key}", "MainPulled")]
  end

  def sha(key) = "#{key}0000000"[0, 7]

  def stamp(clock, offset) = (Time.parse("2026-11-09T#{clock}Z") + offset).utc.iso8601

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

  def spans(cycle) = cycle[:stages].map { |entry| [entry[:stage], entry[:seconds]] }
end

RSpec.describe "the cycle of a Work item" do
  include CycleJournal

  it "measures every stage of a merged item exactly" do
    expect(spans(built(landed_item("ci-observe", "r1") + integrated("ci-observe"))[:cycles].first))
      .to eq([["queue", 435], ["dispatch", 3], ["planning", 79], ["review", 39], ["implementing", 789],
              ["verify", 335], ["boarding", 433], ["ci", 776], ["sync", 51]])
  end

  it "leaves no stage of a merged item open and marks it done" do
    cycle = built(landed_item("ci-observe", "r1") + integrated("ci-observe"))[:cycles].first
    expect(cycle).to include(work: "ci-observe", seconds: 2940, open: nil, done: true)
  end

  it "shows a planned item that never started as queue time only" do
    cycle = built([line("2026-11-09T22:00:00Z", "Tickets::Work", "waiting", "WorkPlanned")])[:cycles].first
    expect(cycle).to include(open: "queue", done: false, stages: [include(stage: "queue", open: true, seconds: 1800)])
  end

  it "shows the open stage of an item still in flight", :aggregate_failures do
    cycle = built(in_flight)[:cycles].first
    expect(cycle[:open]).to eq("dispatch")
    expect(stage(cycle, "dispatch")).to include(open: true, seconds: 1200, end: nil)
  end

  it "closes a landing's verify at the verification of a newer landing that carries it" do
    lines = landed_item("a", "r1") + landed_item("b", "r2", 60) + integrated("b", 60)
    expect(stage(built(lines)[:cycles].find { |cycle| cycle[:work] == "a" }, "verify")).to include(seconds: 395)
  end

  it "never closes a landing's verify at the verification of an older landing" do
    lines = landed_item("a", "r1") + landed_item("b", "r2", 60) + integrated("a", 60)
    expect(stage(built(lines)[:cycles].find { |cycle| cycle[:work] == "b" }, "verify")).to include(open: true)
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
    queue = built(lines)[:stats].find { |entry| entry[:stage] == "queue" }
    expect(queue).to include(median: 435, percentile: 600, items: 3)
    expect(built(lines)[:stats].map { |entry| entry[:stage] })
      .to eq(%w[queue dispatch planning review implementing verify boarding ci sync])
  end
end
