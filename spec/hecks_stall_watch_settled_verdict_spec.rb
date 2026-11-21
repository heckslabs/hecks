require "spec_helper"
require "hecks/hecks/adapters/stall_watching"
require "time"

# A plan review whose architect run ended, as the tap shows it, for the specs of the run-finished
# read: the signal row, the tap lines and the subjects a look lists.
RSpec.shared_context "with a finished run" do
  let(:now) { Time.utc(2026, 11, 21, 12, 0, 0).to_i }
  let(:signal) do
    { kind: "plan-review-unrecorded", aggregate: "Agents::PlanReview", opens: "PlanReviewRequested",
      closes: "PlanReviewed,PlanReviewRecorded", ends_aggregate: "Hecks::AgentRun", ends: "SessionFinished",
      minutes: 5, fixer: "orchestrator", move: "m", cleared_by: "help" }
  end
  let(:verdict) { { settled_aggregate: "Agents::Verdict", settled_by: "VerdictDelivered,VerdictRedelivered" } }

  def line(aggregate, event, minutes_ago)
    { "kind" => "event", "aggregate" => aggregate, "id" => "r1", "event" => event,
      "at" => Time.at(now - (minutes_ago * 60)).utc.iso8601, "links" => {} }
  end

  def lines(*extra)
    [line("Agents::PlanReview", "PlanReviewRequested", 60), line("Hecks::AgentRun", "SessionFinished", 50), *extra]
  end

  def subjects(row, tap) = Hecks::Adapters::StallWatching::FinishedRuns.new(now).rows(row, tap, "look").map { |r| r[:subject] }
end

# A stall row clears when its cause is settled: a recorded verdict leaves no plan-review-unrecorded
# row.
RSpec.describe Hecks::Adapters::StallWatching::FinishedRuns do
  include_context "with a finished run"

  it "lists a review whose run ended with no verdict and no settled fields" do
    expect(subjects(signal, lines)).to eq(["r1"])
  end

  it "leaves a review whose verdict was recorded after it opened" do
    expect(subjects(signal.merge(verdict), lines(line("Agents::Verdict", "VerdictDelivered", 40)))).to be_empty
  end

  it "keeps a review whose settling line came before it opened" do
    early = line("Agents::Verdict", "VerdictDelivered", 90)

    expect(subjects(signal.merge(verdict), [early, *lines])).to eq(["r1"])
  end

  it "settles the live bluebook row on a recorded verdict", pending: "the row names no settled_by yet" do
    source = File.read(File.expand_path("../lib/hecks/hecks/stall_watch/stall_watch.bluebook", __dir__))
    row = source[/plan-review-unrecorded.*?AgentRun\.answer! the waiting coder\./m].to_s

    expect(row).to include("settled_by")
  end
end
