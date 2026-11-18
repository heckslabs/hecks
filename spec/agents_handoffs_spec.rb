require "spec_helper"
require_relative "support/stand_in_claude"

# The roles hand work to each other through pipeline events: a coder's submission asks the reviewer.
# A verified passage asks no one: promote.yml moves stable once every required check passed, so no
# recommendation waits on the owner. Each reaction is seen in the reaction log, and what it made is
# read back through the roles' queries.
RSpec.describe "the agents handing work to each other" do
  include_context "with a stand-in claude"

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def reaction(name)
    @hecks.registry.reaction_log.select { |r| r[:policy] == name }
  end

  it "asks the reviewer when a coder submits work", :aggregate_failures do
    launch("coder", "Submission.submit!", "branch.value=w-sub", "sha.value=abc1234", "checkout.value=#{scratch}",
           "clean.value=true", "--wait")
    expect(reaction("AskTheReviewerWhenWorkIsSubmitted").last[:delivered]).to be(true)
    expect(launch("agents", "SubmissionReview.reviews").first.to_s).to include("w-sub")
  end

  # A passage walked from planned to verified, the way the pipeline's own events carry it.
  def verify_passage(change)
    launch("pipeline", "Passage.plan!", "change.value=#{change}", "--wait")
    launch("pipeline", "Passage.land!", "to=#{change}", "--wait")
    launch("pipeline", "Passage.push!", "to=#{change}", "pushed.value=c841f1d", "--wait")
    launch("pipeline", "Passage.verify!", "to=#{change}", "--wait")
  end

  it "asks no one to recommend a promotion once a passage is verified", :aggregate_failures do
    verify_passage("w-pass")
    expect(reaction("RecommendPromotionWhenVerified")).to be_empty
    expect(launch("agents", "PromotionRecommendation.open").first.to_s).not_to include("w-pass")
  end
end
