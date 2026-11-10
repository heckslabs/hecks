require "spec_helper"
require "hecks/hecks/adapters/ci_runs/checks"

# The checks GitHub lists on a train pull request are measured, not judged: counts, and the names
# of those that concluded without success.
RSpec.describe Hecks::Adapters::CiRuns::Checks do
  let(:passed)  { { "name" => "lint", "status" => "COMPLETED", "conclusion" => "SUCCESS" } }
  let(:failed)  { { "name" => "rspec 8/12", "status" => "COMPLETED", "conclusion" => "FAILURE" } }
  let(:running) { { "name" => "rspec 9/12", "status" => "IN_PROGRESS", "conclusion" => "" } }

  it "counts the checks that concluded", :aggregate_failures do
    checks = described_class.new([passed, failed, running])
    expect(checks.counts).to eq("2 of 3 checks")
    expect(checks.failed).to eq(["rspec 8/12"])
  end

  it "is failed and complete only when no check is left running" do
    expect([[passed, failed], [failed, running]].map { |rollup| described_class.new(rollup).failed_and_complete? })
      .to eq([true, false])
  end

  it "reads commit statuses by their state" do
    status = { "context" => "ci/legacy", "state" => "FAILURE" }
    expect(described_class.new([status]).failed).to eq(["ci/legacy"])
  end

  it "reads a pull request with no rollup as no checks" do
    expect(described_class.new(nil).failed_and_complete?).to be(false)
  end
end
