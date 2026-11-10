require "spec_helper"
require_relative "support/resting_pruner"

# A feature landing wakes the pruner; a run that ends without landing wakes nothing.
RSpec.describe "what wakes the pruner" do
  include_context "with a resting pruner"

  # A fresh runtime for each example, so a pruner run one example starts never holds the next.
  before { @hecks = boot_hecks_in_memory }

  def end_architect_run(run)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=review",
           "agent.value=architect", "--wait")
    finish(run)
  end

  it "starts no pruner when an architect run ends" do
    end_architect_run("w-architect")
    expect(pruners_started).to eq(0)
  end

  it "starts exactly one pruner when a feature lands" do
    land("w-landed")
    expect(pruners_started).to eq(1)
  end

  it "starts one pruner for two landings while it works" do
    land("w-first")
    land("w-second")
    expect(pruners_started).to eq(1)
  end
end
