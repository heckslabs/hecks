require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_settled_looks"

# The standing orchestrator seat ends each turn waiting and never finishes, so the
# agent-run-session row exempts it; any other started run still stalls past its minutes.
RSpec.describe "StallWatch and the standing orchestrator seat" do
  include_context "with a stall watch tap"
  include StallSettledLooks

  it "opens no agent-run-session stall for a seat started past 240 minutes" do
    started("orchestrator-seat")

    expect(stalls).to be_empty
  end

  it "still opens one for a coder run started past 240 minutes" do
    started("coder-run-1")

    expect(stalls).to eq(%w[stall-agent-run-session-coder-run-1])
  end

  it "lists the seat among no impediments" do
    started("orchestrator-seat")

    expect(watching.impediments(run: "look")).to be_empty
  end

  it "abandons no stall for the seat" do
    started("orchestrator-seat")
    append("StallFiled", "stall-agent-run-session-orchestrator-seat", "Hecks::Stall", 1)
    append("AgentRunRetired", "orchestrator-seat", "Hecks::AgentRun", 0)

    expect(watching.abandoned(run: "look")).to be_empty
  end
end
