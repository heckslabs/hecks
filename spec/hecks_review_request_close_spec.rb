require "spec_helper"
require_relative "support/review_request_stand_ins"

# A boarding queued as a pull request sweeps the train pull requests at once, and
# `ReviewRequest.close!` closes one pull request by its number with a comment. The domain is in
# Memory and every port is a stand-in (`ReviewRequestStandIns`).
RSpec.describe "closing pull requests through ReviewRequest" do
  include ReviewRequestStandIns

  before(:all) { @hecks = boot_hecks_in_memory }

  it "sweeps the train pull requests once a boarding is queued", :aggregate_failures do
    names = board.map(&:name)
    expect(names).to include("BoardingQueued", "PullRequestSweepRequested", "PullRequestsSwept")
    expect(names.index("PullRequestSweepRequested")).to be > names.index("BoardingQueued")
  end

  it "keys each boarding's sweep by its own run, so a re-queued commit sweeps again" do
    2.times { board }
    expect(board.map(&:name)).to include("PullRequestsSwept")
  end

  it "closes a pull request by its number with the comment, and records it" do
    expect(close.map(&:name)).to include("PullRequestCloseRequested", "PullRequestsSwept")
  end

  it "sends gh one close with the comment as one argument" do
    close
    expect(gh_calls).to include(["pr", "close", "7", "--comment", "superseded by #9"])
  end

  it "refuses without --confirm and closes nothing", :aggregate_failures do
    expect { close(confirm: false) }.to raise_error(Hecks::Runtime::GivenNotMet, /needs --confirm/)
    expect(gh_calls).to be_empty
  end
end
