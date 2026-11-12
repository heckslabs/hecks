require "spec_helper"
require "json"
require "hecks/hecks/adapters/ci_runs"
require_relative "support/replaced_runs_fixtures"

# A run that a newer run of the same workflow, event and head commit has replaced (a ghost left
# queued by an outage) does not count toward a train pull request's checks.
RSpec.describe Hecks::Adapters::CiRuns::ReplacedRuns do
  include ReplacedRunsFixtures

  def replaced(runs, readable: true, output: nil)
    runner = ->(_argv, **) { [readable, output || JSON.generate(runs)] }
    described_class.new(runner, Dir.pwd, tip)
  end

  it "drops the checks of the older run of the same workflow, event and commit" do
    expect(names(replaced([old_run, new_run]).keep([ghost, check(2)]))).to eq(["job2"])
  end

  it "keeps the checks of a newer run that is still running" do
    running = check(2, status: "IN_PROGRESS", conclusion: "")
    expect(names(replaced([old_run, new_run]).keep([check(1), running]))).to eq(["job2"])
  end

  it "keeps runs of another workflow or another commit" do
    runs = [old_run, run(3, "2026-11-11T21:00:00Z", workflow: "Lint"), run(4, "2026-11-11T22:00:00Z", "abc")]
    expect(replaced(runs).keep([check(1), check(3)]).size).to eq(2)
  end

  it "keeps an entry that names no run, such as a commit status" do
    status = { "context" => "ci/x", "state" => "SUCCESS", "targetUrl" => "https://example.com" }
    expect(replaced([old_run, new_run]).keep([status, { "name" => "n" }]).size).to eq(2)
  end

  it "keeps the whole rollup and says why when the runs cannot be read", :aggregate_failures do
    unread = replaced([], readable: false, output: "boom")
    expect(unread.keep([check(1)]).size).to eq(1)
    expect(unread.unread).to eq("boom")
  end
end
