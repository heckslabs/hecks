require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_settled_looks"

# A subject that settled (a landing whose branch landed, a run whose work item is done) is filed
# for no fixer, and a filed stall whose subject settles is abandoned with its work item dropped.
RSpec.describe "StallWatch settled subjects" do
  include_context "with a stall watch tap"
  include StallSettledLooks

  it "files nothing for a landing whose branch landed under a later landing" do
    carry("landing-1", "work-a", 90)
    carry("landing-2", "work-a", 50, "BranchLanded")

    expect(stalls).to be_empty
  end

  it "files nothing for a run whose work item is already done" do
    started("w1")
    append("WorkFinished", "w1", "Tickets::Work", 10)

    expect(stalls).to be_empty
  end

  it "files a run whose work item was only yielded, since the fixer's own move yields it" do
    started("w1")
    append("WorkYielded", "w1", "Tickets::Work", 10)

    expect(stalls).to eq(%w[stall-agent-run-session-w1])
  end

  it "abandons a filed stall whose subject settled, with the settling line as its reason" do
    started("w1")
    append("StallFiled", "stall-agent-run-session-w1", "Hecks::Stall", 1)
    append("WorkFinished", "w1", "Tickets::Work", 0)

    expect(watching.abandoned(run: "look").map { |row| row[:reason] })
      .to eq(["Hecks::AgentRun w1 can no longer be answered: it settled: Tickets::Work recorded WorkFinished"])
  end

  it "drops the stall's work item once its subject settles" do
    file_then_finish("w1")

    expect(work_status("stall-agent-run-session-w1")).to eq("dropped")
  end
end
