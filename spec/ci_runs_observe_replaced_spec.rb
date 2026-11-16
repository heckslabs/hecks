require "spec_helper"
require "json"
require "hecks/hecks/adapters/ci_runs"
require_relative "support/replaced_runs_fixtures"
require_relative "support/rest_pull_view"
require_relative "support/private_settled_facts"

# An open train pull request is judged without the checks of a run a newer run has replaced.
RSpec.describe Hecks::Adapters::CiRuns, "#watch" do
  include_context "with private settled facts"
  include ReplacedRunsFixtures

  def watch(runs)
    pull = { "number" => 1353, "state" => "OPEN", "commits" => [{ "oid" => tip }], "statusCheckRollup" => [ghost, check(2)] }
    described_class.runner = lambda do |argv, **|
      [true, RestPullView.api?(argv) ? RestPullView.answer(argv, pull) : JSON.generate(runs)]
    end
    described_class.new.watch(landed: tip, checkout: Dir.pwd)[:report][:value]
  end

  after { described_class.runner = nil }

  it "counts only the newer run's checks" do
    expect(watch([old_run, new_run])).to include("(1 of 1 checks)")
  end

  it "counts the ghost when no newer run replaces it" do
    expect(watch([old_run])).to include("(1 of 2 checks)")
  end
end
