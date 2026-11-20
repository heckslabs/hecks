require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_session_looks"

# A stall is a signal, not work: a filed orchestrator stall plans no Tickets work item. It wakes
# the orchestrator once, and that wake requests one run keyed by the stall, with no work item
# behind it.
RSpec.describe "A filed stall as a signal" do
  include_context "with a stall watch tap"
  include StallSessionLooks

  let(:stall) { "stall-agent-run-blocked-w1" }

  before do
    blocked("w1")
    look("look-1")
  end

  it "plans no work item" do
    expect(keys("Tickets", "Work", :work)).to be_empty
  end

  it "raises one escalation" do
    expect(events_named("CoordinatorWoken")).to eq(1)
  end

  it "requests one orchestrator run keyed by the stall" do
    expect(registry.event_log.select { |event| event.name == "AgentRunRequested" }.map { |event| event.id.to_s })
      .to eq([stall])
  end
end
