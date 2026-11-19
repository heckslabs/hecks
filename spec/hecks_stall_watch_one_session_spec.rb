require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_session_looks"

# One stalled item wakes one stall session and a settled one wakes none. The AgentRun rows share
# one group, so a run that is both long started and blocked files one stall, not one per row.
RSpec.describe "StallWatch sessions per stalled item" do
  include_context "with a stall watch tap"
  include StallSessionLooks

  it "wakes one session for the same stall notice over two beats" do
    blocked("w1")
    2.times { |beat| look("look-#{beat}") }

    expect(sessions).to eq(1)
  end

  it "files one stall for a run past its blocked minutes whose session line is young", :aggregate_failures do
    blocked("w1")
    look("look-1")

    expect(keys("Hecks", "Stall", :stall)).to eq(%w[stall-agent-run-blocked-w1])
    expect(sessions).to eq(1)
  end

  it "wakes one session for a run stalled under two rows over two beats" do
    blocked("w1", 300)
    2.times { |beat| look("look-#{beat}") }

    expect(sessions).to eq(1)
  end

  it "wakes no session for a stalled run whose work item is already done" do
    blocked("w1")
    append("WorkFinished", "w1", "Tickets::Work", 10)
    look("look-1")

    expect(sessions).to eq(0)
  end
end
