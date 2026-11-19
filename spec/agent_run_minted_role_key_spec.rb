require "spec_helper"
require_relative "support/stand_in_claude"

# A role's run started by an Agents event takes a minted key, not the commit or request that
# started it, so two runs started for one commit never share a key. A stand-in `claude` and a
# scratch jobs directory keep every session fake, and the runtime is in Memory.
RSpec.describe "AgentRun keys minted for a role's run" do
  include_context "with a stand-in claude"

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def runs = @hecks.registry.repository("Hecks", @hecks.registry.bluebook("Hecks").aggregate("AgentRun"))

  def review(commit)
    launch("agents", "SubmissionReview.request!", "submission.value=#{commit}", "work.value=w-minted",
           "hops.value=1", "role.value=reviewer", "repo.value=#{scratch}", "brief.value=judge w-minted", "--wait")
  end

  def reviewer_runs = runs.all.select { |run| run[:agent] == "reviewer" }

  it "keys the reviewer's run by a minted key, not the submitted commit", :aggregate_failures do
    review("c0ffee1")
    expect(runs.find("c0ffee1")).to be_nil
    expect(reviewer_runs.size).to eq(1)
  end
end
