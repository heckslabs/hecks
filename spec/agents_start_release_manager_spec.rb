require "spec_helper"
require_relative "support/stand_in_claude"

# A recommended promotion starts the release manager's session through AgentRun. A stand-in
# `claude` starts nothing real: the spec shows the recommendation becomes a run keyed by the change.
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

  it "starts a run keyed by the change" do
    recommend("w-release")
    expect(launch("agent_run.running").first.to_s).to include("w-release")
  end

  it "starts no run when the brief says nothing" do
    recommend("w-silent", brief: " ")
    expect(launch("agent_run.running").first.to_s).not_to include("w-silent")
  end

  it "never promotes: the recommendation stays open for the owner" do
    recommend("w-open")
    expect(launch("agents", "PromotionRecommendation.open").first.to_s).to include("w-open")
  end
end
