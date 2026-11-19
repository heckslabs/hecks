require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_session_looks"

# The AgentRun group holds at most three open stalls; a ready line past the cap waits.
RSpec.describe "StallWatch group cap" do
  include_context "with a stall watch tap"
  include StallSessionLooks

  it "files at most three stalls of the group at once" do
    %w[w1 w2 w3 w4].each { |run| blocked(run) }
    look("look-1")

    expect(keys("Hecks", "Stall", :stall).size).to eq(3)
  end

  it "files the waiting run once an open stall's work item settles" do
    %w[w1 w2 w3 w4].each { |run| blocked(run) }
    look("look-1")
    append("WorkFinished", "stall-agent-run-blocked-w1", "Tickets::Work", 0)
    look("look-2")

    expect(keys("Hecks", "Stall", :stall)).to eq(%w[stall-agent-run-blocked-w4])
  end
end
