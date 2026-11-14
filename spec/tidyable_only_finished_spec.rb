# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"

# What a spec of a reap among ended runs builds and reads: a run retired while started, a run its
# own end tidied, a finished run the review keeps, each run's status, and the runs one reap sent
# `Tidy` to.
module EndedRuns
  # The listing holds no session, so the reap the run's end starts records `r-tidied` tidied.
  def ended_runs
    File.write(File.join(scratch, "sessions.json"), "[]")
    launch("agent_run.dispatch!", "run.value=r-retired", "repo.value=#{scratch}", "brief.value=go", "--wait")
    launch("agent_run.retired!", "to=r-retired", "detail.value=gone", "--wait")
    finished_run("r-tidied")
  end

  # A person replied in the listed session, so the reap the run's end starts keeps it finished.
  def kept_run
    transcript([user("go"), user("one more thing")])
    listing("stand-in-session", "done")
    finished_run("r-finished")
  end

  def status_of(run)
    registry = @hecks.registry
    registry.repository("Hecks", registry.bluebook("Hecks").aggregate("AgentRun")).find(run)&.[](:status)
  end

  # The row each reaction of a reap's fan-out names, every reap of the example counted.
  def tidy_sent_to
    @hecks.registry.reaction_log.select { |record| record[:policy] == "TidyEveryFinishedRun" }.map { |record| record[:for_row] }
  end

  # The runs the reap under test sent `Tidy` to: the log is cut where that reap begins, so the
  # `Tidy` each run's own end sent while the run was finished is left out.
  def tidy_sent_by_reap
    before = tidy_sent_to.size
    reap
    tidy_sent_to.drop(before)
  end
end

# `AgentRun.Tidyable` answers the finished runs and no others, so a reap sends `Tidy` to no run
# that is already tidied or retired. What the reap does with the finished run is not judged here.
RSpec.describe "A reap with tidied and retired runs present" do
  include_context "with a reaping fleet"
  include EndedRuns

  before do
    transcript([user("go")])
    ended_runs
    kept_run
  end

  it "starts from one run in each state" do
    expect(%w[r-retired r-tidied r-finished].map { |run| status_of(run) }).to eq(%w[retired tidied finished])
  end

  it "lists only the finished run as tidyable" do
    expect(JSON.parse(launch("agent_run.tidyable")).map { |row| row["run"] }).to eq(["r-finished"])
  end

  it "sends Tidy to the finished run alone, neither the tidied nor the retired one" do
    expect(tidy_sent_by_reap).to eq(["r-finished"])
  end

  it "leaves the tidied and the retired run as they were" do
    reap
    expect(%w[r-retired r-tidied].map { |run| status_of(run) }).to eq(%w[retired tidied])
  end
end
