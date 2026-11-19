require "spec_helper"
require_relative "support/boarding_sweep_stand_ins"

# A boarding queued as a train pull request sweeps the open train pull requests at once
# (`SweepTrainPullRequestsWhenQueued`), as the heartbeat does on its beat. The domain is in
# Memory and every port is a stand-in (`BoardingSweepStandIns`).
RSpec.describe "SweepTrainPullRequestsWhenQueued" do
  include BoardingSweepStandIns

  before(:all) { @hecks = boot_hecks_in_memory }

  def names = board.map(&:name)

  it "sweeps after the boarding is queued and records what it closed", :aggregate_failures do
    recorded = names
    expect(recorded).to include("BoardingQueued", "PullRequestSweepRequested", "PullRequestsSwept")
    expect(recorded.index("PullRequestSweepRequested")).to be > recorded.index("BoardingQueued")
  end

  it "keys each boarding's sweep by its own run, so a second boarding sweeps again" do
    board
    expect(names).to include("PullRequestsSwept")
  end

  it "records a sweep GitHub refuses as refused and leaves the boarding queued", :aggregate_failures do
    @tidy_refuses = true
    recorded = names
    expect(recorded).to include("BoardingQueued", "TidyRefused")
    expect(recorded).not_to include("PullRequestsSwept")
  end
end
