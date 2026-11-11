require "spec_helper"
require_relative "support/resting_pruner"

# One pruner at a time, and a new run key (minted by the reaction) for each. Each example boots its
# own runtime and starts every pruner it counts, so no other spec's landing or pruner leaks in.
RSpec.describe "the pruner's turn" do
  include_context "with a resting pruner"

  def session_reads_done
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: "done"))
  end

  it "starts no second pruner while one is working" do
    2.times { launch("agents", "pruning.summon!", "role.value=pruner", "repo.value=#{scratch}", "brief.value=prune", "--wait") }
    expect(pruners_started).to eq(1)
  end

  it "dispatches a pruner again once the first has ended, under a new run key" do
    session_reads_done
    launch!("agents", "pruning.summon!", "role.value=pruner", "repo.value=#{scratch}", "brief.value=prune", "--wait")
    launch!("agents", "pruning.wake!", "to=pruner", "repo.value=#{scratch}", "brief.value=prune", "--wait")
    expect(pruners_started).to eq(2)
  end
end
