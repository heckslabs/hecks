require "spec_helper"
require_relative "support/resting_pruner"

# A landing does not wake the pruner: it starts the mechanical reap of finished sessions instead,
# and a run that ends without landing wakes nothing.
RSpec.describe "what wakes the pruner" do
  include_context "with a resting pruner"

  def end_architect_run(run)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=review",
           "agent.value=architect", "--wait")
    finish(run)
  end

  it "starts no pruner when an architect run ends" do
    end_architect_run("w-architect")
    expect(pruners_started).to eq(0)
  end

  it "starts no pruner when a feature lands" do
    land("w-landed")
    expect(pruners_started).to eq(0)
  end

  it "starts no pruner for two landings" do
    land("w-first")
    land("w-second")
    expect(pruners_started).to eq(0)
  end
end
