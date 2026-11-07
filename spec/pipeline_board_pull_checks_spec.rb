# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"

# The train pull requests the Snapshot lists, and how their checks are counted.
RSpec.describe Hecks::Adapters::PipelineBoard::PullChecks do
  def pull(*checks) = { "number" => 1, "headRefName" => "train/x", "statusCheckRollup" => checks }

  it "counts a check run's conclusion and a status context's state" do
    checks = [{ "conclusion" => "SUCCESS" }, { "conclusion" => "SKIPPED" }, { "conclusion" => "TIMED_OUT" },
              { "status" => "IN_PROGRESS", "conclusion" => "" }, { "state" => "PENDING" }, { "state" => "ERROR" }]
    counted = { number: 1, branch: "train/x", total: 6, passed: 2, failed: 2, pending: 2 }
    expect(described_class.train([pull(*checks)])).to eq([counted])
  end

  it "leaves out a pull request that is not on a train branch" do
    other = { "number" => 2, "headRefName" => "feature/y", "statusCheckRollup" => [] }
    expect(described_class.train([other])).to eq([])
  end
end
