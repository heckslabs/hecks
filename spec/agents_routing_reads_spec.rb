require "spec_helper"
require_relative "support/routing_reads_helper"

# The read-only verbs the orchestrator needs to route without a shell.
RSpec.describe "the orchestrator routing reads" do
  include RoutingReadsHelper

  [
    "Dispatch.preview", "Dispatch.fill!", "AgentRun.running", "AgentRun.retire!", "ReviewRequest.status",
    "ReviewRequest.take!", "PushRehearsal.due", "PushRehearsal.rehearse!", "Workspace.status",
    "LinkedTree.pull_main!", "SendTrain.board!", "Machine.sample!"
  ].each do |verb|
    it "allows #{verb}" do
      expect(verdict("exe/hecks #{verb} x.value=1")).to eq(text: "allowed")
    end
  end

  it "refuses uptime, naming the verbs that read the load", :aggregate_failures do
    expect(refusal("uptime")).to include("Machine.sample!")
    expect(refusal("uptime")).to include("Dispatch.preview")
  end

  it "names the nearest verb of the same aggregate for an unlisted verb" do
    expect(refusal("exe/hecks Machine.record! x=1")).to include("Machine.sample!")
  end
end
