require "spec_helper"
require_relative "support/stand_in_claude"

# A recommended promotion starts the release manager's session through AgentRun. A stand-in
# `claude` starts nothing real: the spec shows the recommendation becomes a run under a minted key.
RSpec.describe "a promotion recommendation starting the release manager's session" do
  include_context "with a stand-in claude"

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def recommend(change, brief: "recommend promote, revert or fix forward, with reasons")
    launch("agents", "PromotionRecommendation.recommend!", "change.value=#{change}", "reasons.value=green",
           "role.value=release_manager", "repo.value=#{scratch}", "brief.value=#{brief}", "--wait")
  end

  def runs = @hecks.registry.repository("Hecks", @hecks.registry.bluebook("Hecks").aggregate("AgentRun"))

  def manager_runs = runs.all.select { |run| run[:agent]&.value == "release_manager" }

  it "starts a release manager's run under a minted key, not the change", :aggregate_failures do
    before = manager_runs.size
    recommend("w-release")
    expect(manager_runs.size).to eq(before + 1)
    expect(runs.find("w-release")).to be_nil
  end

  it "starts no run when the brief says nothing" do
    before = manager_runs.size
    recommend("w-silent", brief: " ")
    expect(manager_runs.size).to eq(before)
  end

  it "never promotes: the recommendation stays open for the owner" do
    recommend("w-open")
    expect(launch("agents", "PromotionRecommendation.open").first.to_s).to include("w-open")
  end
end
