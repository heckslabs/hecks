require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/impediment_looks"

# The impediment view names the stalls the scrum master watches from readings that exist already:
# starts held while the load is low, leftovers over a count, a plan review whose architect run
# finished without a verdict, and landings slower than the day's rate.
RSpec.describe "StallWatch impediments: the scrum master's marks" do
  include_context "with a stall watch tap"
  include ImpedimentLooks

  let(:load_now)  { 1.5 }
  let(:counts)    { { "finished-sessions" => 3, "worktrees" => 4, "merged-branches" => 2 } }
  let(:stalled)   { ->(reason, ago) { ["FillStalled", "fill", ago, "Hecks::FillStall", { "reason" => reason }] } }

  def watching
    aggregate = registry.bluebook("Hecks").aggregate("StallWatch")
    Hecks::Adapters::StallWatching.new(registry: registry, aggregate: aggregate, tap: tap, branches: branch_read,
                                       load: -> { load_now }, leftovers: ->(name) { counts.fetch(name) })
  end

  it "lists starts held by the load pause while the load is under the low mark", :aggregate_failures do
    write_sources([stalled.call("4 held by load pause", 25)])

    expect(row_of("starts-held-by-load")).to include(subject: "fill", cleared_by: "help", fixer: "orchestrator")
    expect(row_of("starts-held-by-load")[:waited]).to be >= 10
  end

  it "leaves the load pause alone while the load is over the low mark" do
    write_sources([stalled.call("4 held by load pause", 25)])
    allow(self).to receive(:load_now).and_return(14.0)

    expect(kinds).not_to include("starts-held-by-load")
  end

  it "leaves a start held by the load pause for under ten minutes" do
    write_sources([stalled.call("4 held by load pause", 6)])
    expect(kinds).not_to include("starts-held-by-load")
  end

  it "counts a load pause only from the last time the load fell under the mark" do
    write_sources([stalled.call("4 held by load pause", 25), ["LoadFellBelow", "launchd-1", 4, "Hecks::Machine"]])
    expect(kinds).not_to include("starts-held-by-load")
  end

  it "lists starts held by a breaker for thirty minutes while the load is low" do
    write_sources([stalled.call("2 held by breaker", 45)])
    expect(kinds).to include("starts-held-by-breaker")
  end

  it "leaves a start held by a breaker for under thirty minutes" do
    write_sources([stalled.call("2 held by breaker", 20)])
    expect(kinds).not_to include("starts-held-by-breaker")
  end

  it "leaves the hold once the fill moves again" do
    write_sources([stalled.call("4 held by load pause", 25), ["FillStallCleared", "fill", 1, "Hecks::FillStall"]])
    expect(kinds).not_to include("starts-held-by-load")
  end

  it "lists each leftover kind over its count", :aggregate_failures do
    counts.merge!("finished-sessions" => 40, "worktrees" => 30, "merged-branches" => 25)
    write_sources([])

    expect(kinds).to include("finished-sessions-standing", "worktrees-standing", "merged-branches-standing")
    expect(row_of("worktrees-standing")[:detail]).to include("30")
  end

  it "lists no leftovers under their counts" do
    write_sources([])
    expect(kinds).to be_empty
  end

  it "lists a plan review whose architect run finished with no verdict", :aggregate_failures do
    review = ["PlanReviewRequested", "run-a", 40, "Agents::PlanReview", { "work" => "the-item" }]
    write_sources([review, ["SessionFinished", "run-a", 30, "Hecks::AgentRun"]])

    expect(row_of("plan-review-unrecorded")).to include(subject: "run-a", cleared_by: "help")
    expect(row_of("plan-review-unrecorded")[:detail]).to include("the-item")
  end

  it "leaves a plan review whose verdict was recorded" do
    write_sources([["PlanReviewRequested", "run-a", 40, "Agents::PlanReview"],
                   ["SessionFinished", "run-a", 30, "Hecks::AgentRun"],
                   ["PlanReviewRecorded", "run-a", 20, "Agents::PlanReview"]])
    expect(kinds).not_to include("plan-review-unrecorded")
  end

  it "leaves a plan review whose architect run is still going" do
    write_sources([["PlanReviewRequested", "run-a", 40, "Agents::PlanReview"]])
    expect(kinds).not_to include("plan-review-unrecorded")
  end

  it "lists landings in the last hour under half the three-hour rate" do
    landed = [150, 120, 100, 90, 80, 70].map { |ago| ["BranchLanded", "l-#{ago}", ago, "Delivery::Landing"] }
    write_sources(landed)

    expect(kinds).to include("landing-rate-low")
  end

  it "leaves a landing rate at the three-hour rate" do
    landed = [50, 40, 100, 120, 170].map { |ago| ["BranchLanded", "l-#{ago}", ago, "Delivery::Landing"] }
    write_sources(landed)

    expect(kinds).not_to include("landing-rate-low")
  end
end
