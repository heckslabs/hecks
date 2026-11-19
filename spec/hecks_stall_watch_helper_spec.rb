require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_session_looks"

# A helper's block starts no helper: a run seated to answer a question is never filed, while the
# run that asked still is, and a run the tap ties to no work item is labelled unnamed.
RSpec.describe "StallWatch helpers" do
  include_context "with a stall watch tap"
  include StallSessionLooks

  it "files nothing and wakes no session for a blocked answerer over two beats", :aggregate_failures do
    blocked_answerer("a1", "w9")
    2.times { |beat| look("look-#{beat}") }

    expect(keys("Hecks", "Stall", :stall)).to be_empty
    expect(sessions).to eq(0)
  end

  it "still files the blocked run its answerer answers" do
    blocked("w1")
    blocked_answerer("a1", "w1")
    look("look-1")

    expect(keys("Hecks", "Stall", :stall)).to eq(%w[stall-agent-run-blocked-w1])
  end

  it "labels a blocked run with no work item unnamed until a work line names it", :aggregate_failures do
    blocked("r1")
    expect(blocked_detail("r1")).to include("Unnamed run")

    append("WorkStarted", "r1", "Tickets::Work", 25)
    expect(blocked_detail("r1")).not_to include("Unnamed run")
  end
end
