# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"

# What a spec of a reap among ended runs builds and reads: a run retired while started, a run
# recorded tidied, each run's status, and the runs a reap sent `Tidy` to.
module EndedRuns
  def ended_runs
    launch("agent_run.dispatch!", "run.value=r-retired", "repo.value=#{scratch}", "brief.value=go", "--wait")
    launch("agent_run.retired!", "to=r-retired", "detail.value=gone", "--wait")
    finished_run("r-tidied")
    launch("agent_run.tidied!", "to=r-tidied", "tidied_at.value=2026-11-11T12:00:00Z", "--wait")
  end

  def status_of(run)
    registry = @hecks.registry
    registry.repository("Hecks", registry.bluebook("Hecks").aggregate("AgentRun")).find(run)&.[](:status)
  end

  # The row each reaction of the reap's fan-out names.
  def tidy_sent_to
    @hecks.registry.reaction_log.select { |record| record[:policy] == "TidyEveryFinishedRun" }.map { |record| record[:for_row] }
  end
end

# `AgentRun.Tidyable` answers the finished runs and no others, so a reap sends `Tidy` to no run
# that is already tidied or retired. What the reap does with the finished run is not judged here.
RSpec.describe "A reap with tidied and retired runs present" do
  include_context "with a reaping fleet"
  include EndedRuns

  before do
    File.write(File.join(scratch, "sessions.json"), "[]")
    transcript([user("go")])
    ended_runs
    finished_run("r-finished")
  end

  it "starts from one run in each state" do
    expect(%w[r-retired r-tidied r-finished].map { |run| status_of(run) }).to eq(%w[retired tidied finished])
  end

  it "lists only the finished run as tidyable" do
    expect(JSON.parse(launch("agent_run.tidyable")).map { |row| row["run"] }).to eq(["r-finished"])
  end

  it "sends Tidy to neither the tidied nor the retired run" do
    reap
    expect(tidy_sent_to).not_to include("r-tidied", "r-retired")
  end

  it "leaves the tidied and the retired run as they were" do
    reap
    expect(%w[r-retired r-tidied].map { |run| status_of(run) }).to eq(%w[retired tidied])
  end
end
